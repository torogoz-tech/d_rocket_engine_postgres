/// The Postgres connection pool.
///
/// Implements [AsyncQueryProvider] over a
/// pool of N [PostgresQueryProvider]s. Each
/// call to `selectAsync` / `executeAsync`
/// acquires a connection from the pool,
/// runs the operation, and releases the
/// connection back. Transactions hold the
/// same connection for the entire
/// `beginTransactionAsync` / `commitAsync` /
/// `rollbackAsync` cycle (so the BEGIN /
/// COMMIT happen on the same wire).
///
/// ## The pool is engine-specific
///
/// `PostgresPool` is **not** in d_rocket
/// core — only the Postgres engine has one.
/// The core's [AsyncQueryProvider] contract
/// is the same, but the implementation
/// differs per engine:
///   - SQLite: 1 connection (file handle)
///   - Postgres: 1..N connections (pool)
///   - MySQL (future): 1..N connections (pool)
///   - libsql_wasm (future): 1 connection
///     (WASM, single-writer)
///
/// ## Concurrency model
///
/// The pool uses a list of idle connections
/// and a counter of in-use connections. The
/// acquire/release are synchronous (no locks
/// needed in Dart's single-threaded event
/// loop, but we still use a Completer for
/// the wait queue to avoid busy-polling).
///
/// ## Limitations (for 2.0.0)
///
/// * The pool does NOT support "session"
///   state (e.g. `SET search_path = ...` per
///   connection). Each connection is
///   interchangeable. If you need per-
///   request session state, use the
///   underlying [PostgresQueryProvider]
///   directly.
/// * The pool does NOT do idle eviction
///   automatically yet (the idleTimeout
///   is stored in the config but the
///   eviction task is a 2.1 feature).
///   Connections are kept until [disposeAsync].
/// * The pool does NOT auto-reconnect. If
///   a connection dies (server restart,
///   network blip), the next request on
///   that connection fails. The user code
///   should retry the operation (a 2.1
///   feature will add automatic retry).
library;

import 'dart:async';
import 'dart:collection';

import 'package:d_rocket/d_rocket.dart';

import 'pool_config.dart';
import 'query_provider.dart';

/// A connection pool for the Postgres engine.
///
/// The pool implements [AsyncQueryProvider]
/// so it is a drop-in replacement for a
/// single [PostgresQueryProvider] — the rest
/// of d_rocket (the LINQ, the DbContext,
/// the migrations) does not need to know
/// that the engine is pooled.
class PostgresPool implements AsyncQueryProvider {
  final String _url;
  final String? _password;
  final PoolConfig _config;

  /// Idle connections available to be
  /// acquired. FIFO order (oldest first)
  /// to keep idle time fair.
  final Queue<PostgresQueryProvider> _idle = Queue<PostgresQueryProvider>();

  /// Total connections currently allocated
  /// (idle + in-use). Used to enforce [max].
  int _total = 0;

  /// Pending acquire requests (FIFO queue
  /// of Completers that resolve when a
  /// connection is released).
  final Queue<Completer<PostgresQueryProvider>> _waiters =
      Queue<Completer<PostgresQueryProvider>>();

  /// The connection currently held by a
  /// transaction (if any). Keyed by the
  /// caller's identity (we use a single-
  /// transaction policy: the pool itself
  /// is single-tenant, so at most one
  /// transaction at a time).
  PostgresQueryProvider? _txnConn;

  /// Disposed flag. After [disposeAsync] the
  /// pool refuses all operations.
  bool _disposed = false;

  PostgresPool._(this._url, this._password, this._config);

  /// Opens a pool. Pre-opens [PoolConfig.min]
  /// connections (the warmup) so the first
  /// few requests don't pay the TCP+TLS+auth
  /// cost.
  static Future<PostgresPool> open({
    required String url,
    String? password,
    required PoolConfig config,
  }) async {
    final PostgresPool pool = PostgresPool._(url, password, config);
    await pool._warmup();
    return pool;
  }

  /// Pre-opens [PoolConfig.min] connections.
  /// If any warmup connection fails, the
  /// pool is disposed and the error is
  /// rethrown wrapped in [DatabaseException].
  Future<void> _warmup() async {
    for (int i = 0; i < _config.min; i++) {
      try {
        final PostgresQueryProvider conn = await _openOne();
        _idle.add(conn);
        _total++;
      } on Object catch (e) {
        await _disposeAll();
        throw DatabaseException(
          'PostgresPool warmup failed after $i of '
          '${_config.min} connections: $e',
          cause: e,
        );
      }
    }
  }

  /// Opens a single connection with the
  /// configured [PoolConfig.connectionTimeout].
  Future<PostgresQueryProvider> _openOne() async {
    return await _connTimeout().timeout(
      _config.connectionTimeout,
      onTimeout: () => throw TimeoutException(
        'Postgres connection open timed out after '
        '${_config.connectionTimeout}',
      ),
    );
  }

  /// Wraps the underlying open in a Future
  /// so it composes with [Future.timeout].
  Future<PostgresQueryProvider> _connTimeout() {
    return PostgresQueryProvider.openFromUrl(
      url: _url,
      password: _password,
    );
  }

  /// Acquires a connection. Returns one of:
  ///   - an idle connection (if any)
  ///   - a newly-opened one (if under [max])
  ///   - waits for one to be released
  ///     (if at [max] and the queue has
  ///     a slot).
  ///
  /// Throws [DatabaseException] on
  /// [acquireTimeout] (pool exhausted) or
  /// on connection-open failure.
  Future<PostgresQueryProvider> _acquire() async {
    if (_disposed) {
      throw StateError('PostgresPool: acquire called after dispose');
    }
    // Fast path: idle connection available.
    if (_idle.isNotEmpty) {
      return _idle.removeFirst();
    }
    // Fast path: under max — open a new one.
    if (_total < _config.max) {
      try {
        final PostgresQueryProvider conn = await _openOne();
        _total++;
        return conn;
      } on Object catch (e) {
        throw DatabaseException(
          'PostgresPool: failed to open a new connection '
          '(total: $_total, max: ${_config.max}): $e',
          cause: e,
        );
      }
    }
    // Slow path: at max, wait for a release.
    final Completer<PostgresQueryProvider> waiter =
        Completer<PostgresQueryProvider>();
    _waiters.add(waiter);
    try {
      return await waiter.future.timeout(
        _config.acquireTimeout,
        onTimeout: () {
          _waiters.remove(waiter);
          throw DatabaseException(
            'PostgresPool: acquire timed out after '
            '${_config.acquireTimeout} (pool exhausted: '
            '$_total/${_config.max} connections in use, '
            '${_waiters.length + 1} waiters). Either raise '
            'PoolConfig.max, lower the request rate, or '
            'add more app instances.',
          );
        },
      );
    } on Object {
      // If the timeout fired, the waiter was
      // removed. If any other error, the
      // Completer was never resolved — we
      // also remove it to avoid leaks.
      if (!waiter.isCompleted) {
        _waiters.remove(waiter);
      }
      rethrow;
    }
  }

  /// Releases a connection back to the pool.
  /// If a waiter is queued, the connection
  /// is handed to the waiter immediately
  /// (FIFO). Otherwise it goes to the idle
  /// list.
  ///
  /// If the connection is dead (server
  /// restart, network blip), it is not
  /// returned to the pool — the slot is
  /// freed (so the pool can open a fresh
  /// one on demand).
  void _release(PostgresQueryProvider conn) {
    _total--;
    if (_waiters.isNotEmpty) {
      final Completer<PostgresQueryProvider> waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(conn);
      }
      // _total is the same (one in, one out
      // of the pool's perspective). Restore
      // the count.
      _total++;
    } else {
      _idle.add(conn);
    }
  }

  // ─── AsyncQueryProvider implementation ─────────────────

  @override
  bool get isOpen => !_disposed && _total > 0;

  /// Stats. Useful for monitoring / tests.
  int get idleCount => _idle.length;
  int get totalCount => _total;
  int get waiterCount => _waiters.length;

  @override
  Future<void> executeAsync(String sql, [List<Object?>? binds]) async {
    final PostgresQueryProvider conn = await _acquire();
    try {
      await conn.executeAsync(sql, binds);
    } finally {
      _release(conn);
    }
  }

  @override
  Future<List<Object?>> selectAsync(String sql, [List<Object?>? binds]) async {
    final PostgresQueryProvider conn = await _acquire();
    try {
      return await conn.selectAsync(sql, binds);
    } finally {
      _release(conn);
    }
  }

  @override
  Future<int> lastInsertRowIdAsync() async {
    final PostgresQueryProvider conn = await _acquire();
    try {
      return await conn.lastInsertRowIdAsync();
    } finally {
      _release(conn);
    }
  }

  /// Begin a transaction. The pool holds ONE
  /// transaction connection at a time (so
  /// concurrent transactions on the same
  /// pool are serialized). The next
  /// acquire / release cycle on the pool
  /// uses this same connection.
  ///
  /// This is a deliberate simplification
  /// for 2.0.0. A future version will
  /// support true concurrent transactions
  /// (each on its own connection).
  @override
  Future<void> beginTransactionAsync() async {
    if (_txnConn != null) {
      throw StateError(
        'PostgresPool: nested transactions are not supported '
        'in 2.0.0. Commit or rollback the outer transaction '
        'first.',
      );
    }
    final PostgresQueryProvider conn = await _acquire();
    try {
      await conn.beginTransactionAsync();
      _txnConn = conn;
    } catch (e) {
      _release(conn);
      rethrow;
    }
  }

  @override
  Future<void> commitAsync() async {
    final PostgresQueryProvider? conn = _txnConn;
    if (conn == null) return;
    _txnConn = null;
    try {
      await conn.commitAsync();
    } finally {
      _release(conn);
    }
  }

  @override
  Future<void> rollbackAsync() async {
    final PostgresQueryProvider? conn = _txnConn;
    if (conn == null) return;
    _txnConn = null;
    try {
      await conn.rollbackAsync();
    } finally {
      _release(conn);
    }
  }

  @override
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    await _disposeAll();
  }

  Future<void> _disposeAll() async {
    // Fail all pending waiters so they don't hang.
    for (final Completer<PostgresQueryProvider> waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          StateError('PostgresPool: disposed while request was waiting'),
        );
      }
    }
    _waiters.clear();
    // Close all idle connections.
    for (final PostgresQueryProvider conn in _idle) {
      try {
        await conn.disposeAsync();
      } on Object {
        // Swallow — we're tearing down anyway.
      }
    }
    _idle.clear();
    // If a transaction was open, try to rollback
    // before closing.
    final PostgresQueryProvider? txn = _txnConn;
    _txnConn = null;
    if (txn != null) {
      try {
        await txn.rollbackAsync();
      } on Object {
        // Swallow.
      }
      try {
        await txn.disposeAsync();
      } on Object {
        // Swallow.
      }
    }
    _total = 0;
  }
}
