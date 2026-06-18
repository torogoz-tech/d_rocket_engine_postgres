/// Configuration for the [PostgresPool] that the
/// [PostgresEngine] opens.
///
/// The pool is **engine-specific** — only the
/// Postgres engine has one. SQLite is a single-
/// writer file (no pool needed). MySQL, MSSQL,
/// libsql_wasm (when added) will have their own
/// pool configs in their own engine packages.
///
/// ## What the parameters control
///
/// * [min] — the pool pre-opens [min] connections
///   at startup so the first few requests don't
///   pay the TCP+TLS+auth cost. The pool never
///   shrinks below [min] (idle connections are
///   kept, not closed).
///
/// * [max] — the pool will never open more than
///   [max] connections concurrently. Requests
///   beyond [max] wait (queued, see
///   [acquireTimeout]).
///
/// * [idleTimeout] — connections that have been
///   idle for this duration beyond [min] are
///   eligible for eviction. The pool re-opens
///   a connection on demand to maintain [min].
///
/// * [connectionTimeout] — the time given to
///   open a single TCP+TLS+auth connection.
///   If exceeded, the open fails with
///   [DatabaseException].
///
/// * [acquireTimeout] — the time a request
///   waits for a connection to become
///   available. If exceeded, the request
///   fails with [DatabaseException] (the
///   pool is exhausted).
///
/// ## Why per-engine and not per-`PgDb.open`
///
/// Engine-specific config lives on the engine
/// constructor, not on the facade. The
/// `PgDb.open` signature is engine-agnostic;
/// only the `PostgresEngine` constructor has
/// the pool config. This way the
/// `SqliteEngine` doesn't have a `pool:`
/// field (it doesn't need one), and the
/// facade is not polluted with engine-
/// specific parameters.
///
/// ## Usage
///
/// ```dart
/// // Default (1 conn min, 10 conn max).
/// const engine = PostgresEngine();
///
/// // Tuned for high-traffic prod.
/// const engine = PostgresEngine(
///   pool: const PoolConfig(
///     min: 4,
///     max: 32,
///     idleTimeout: Duration(minutes: 5),
///     connectionTimeout: Duration(seconds: 10),
///     acquireTimeout: Duration(seconds: 30),
///   ),
/// );
///
/// final db = await PgDb.open(
///   url: 'postgres://...',
///   engine: engine,
/// );
/// ```
library;

import 'package:d_rocket/d_rocket.dart';

/// Pool config for the Postgres engine.
///
/// Value class. Safe to pass `const`.
class PoolConfig {
  /// Minimum number of connections the pool
  /// keeps open. The pool pre-opens this many
  /// at startup (warmup) and never closes
  /// below this threshold.
  ///
  /// Default: `1`. For production, set this
  /// to ~2-4 so the first few requests don't
  /// pay the open cost.
  final int min;

  /// Maximum number of connections the pool
  /// will open concurrently. Requests beyond
  /// this wait (queued, see [acquireTimeout]).
  ///
  /// Default: `10`. For production, set this
  /// to the Postgres server's `max_connections`
  /// divided by the number of app instances,
  /// minus a headroom for the server's
  /// own connections.
  final int max;

  /// How long a connection above [min] may sit
  /// idle before it is closed. Set to
  /// [Duration.zero] to disable idle eviction
  /// (the pool always keeps [max] connections
  /// open).
  ///
  /// Default: `5 minutes`.
  final Duration idleTimeout;

  /// Time given to open a single TCP+TLS+auth
  /// connection. If exceeded, the open fails
  /// with [DatabaseException] and the pool
  /// marks the slot as available (so the next
  /// request can try again).
  ///
  /// Default: `30 seconds`.
  final Duration connectionTimeout;

  /// How long a request waits for a
  /// connection to become available. If
  /// exceeded, the request fails with
  /// [DatabaseException] (the pool is
  /// exhausted — either raise [max] or
  /// add more app instances).
  ///
  /// Default: `10 seconds`.
  final Duration acquireTimeout;

  const PoolConfig({
    this.min = 1,
    this.max = 10,
    this.idleTimeout = const Duration(minutes: 5),
    this.connectionTimeout = const Duration(seconds: 30),
    this.acquireTimeout = const Duration(seconds: 10),
  })  : assert(min >= 0, 'min must be >= 0'),
        assert(max >= 1, 'max must be >= 1'),
        assert(min <= max, 'min ($min) must be <= max ($max)');

  @override
  String toString() => 'PoolConfig('
      'min: $min, '
      'max: $max, '
      'idleTimeout: $idleTimeout, '
      'connectionTimeout: $connectionTimeout, '
      'acquireTimeout: $acquireTimeout)';
}
