/// The `PgDb` facade for d_rocket 2.0 with the
/// Postgres engine.
///
/// Mirrors the SQLite engine's `Db` class:
/// the consumer opens a `PgDb` with a connection
/// URL, then gets a `DbContext` via
/// `db.context` (or just uses the auto-generated
/// `db.set<T>()` extensions).
///
/// ## Why a separate class
///
/// The SQLite engine ships `Db` because the
/// SQLite engine is the only one shipping in
/// 2.0 that uses the SQL LINQ path. The
/// Postgres engine is a raw-SQL engine in
/// 2.0.0; the SQL LINQ / `db.set<T>().where()`
/// is a 2.1 feature. For 2.0.0 the user uses
/// the Postgres `QueryProvider` directly for
/// queries, and `PgDb.context` to access the
/// `DbContext` for migrations, change tracking,
/// and the auto-migrator.
///
/// ## Usage
///
/// ```dart
/// import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
///
/// Future<void> main() async {
///   dRocketPostgres();  // 1. infra: registrar el engine (una vez)
///   initializeD();      // 2. app: registrar las entidades del codegen
///
///   final db = await PgDb.open(
///     url: 'postgres://app:secret@localhost:5432/mydb',
///   );
///   try {
///     final rows = await db.provider.selectAsync(
///       'SELECT id, name FROM users WHERE active = \$1',
///       [true],
///     );
///     print(rows);
///   } finally {
///     await db.close();
///   }
/// }
/// ```
library;

import 'package:d_rocket/d_rocket.dart';

import 'pg/query_provider.dart';

/// The Postgres-engine [Db] facade.
class PgDb {
  final PostgresQueryProvider _provider;
  final DbContext _context;

  PgDb._(this._provider, this._context);

  /// The raw Postgres provider. Use this for
  /// direct SQL queries (SELECT / INSERT /
  /// UPDATE / DELETE).
  PostgresQueryProvider get provider => _provider;

  /// The engine-agnostic DbContext. Use this
  /// for migrations, change tracking, the
  /// auto-migrator, and the `db.set<T>()`
  /// extensions in d_rocket core.
  DbContext get context => _context;

  /// Whether the underlying connection is
  /// still open.
  bool get isOpen => _provider.isOpen;

  /// Opens a Postgres connection and returns a
  /// ready-to-use [PgDb].
  ///
  /// The [url] is a Postgres connection URL
  /// (e.g. `postgres://user:pass@host:5432/db`).
  /// The [password] is a fallback when the URL
  /// has no embedded password.
  ///
  /// If [entityMetas] is non-empty, the
  /// `DbContext` is registered with the given
  /// entity list (used by the auto-migrator).
  /// If [autoMigrate] is true, the auto-
  /// migrator runs after the open.
  static Future<PgDb> open({
    required String url,
    String? password,
    List<EntityMeta> entityMetas = const <EntityMeta>[],
    bool autoMigrate = false,
  }) async {
    final DbEngine engine = EngineRegistry.findOrThrow;
    if (engine.name != 'postgres') {
      throw DatabaseException(
        'PgDb is the Postgres engine facade; the registered '
        'engine is "${engine.name}". Use the engine-specific '
        'facade (Db for d_rocket_engine_sqlite) for a '
        'different backend, or register the Postgres engine '
        'with dRocketPostgres() before calling PgDb.open.',
        cause: engine.name,
      );
    }
    final AsyncQueryProvider raw = await engine.open(
      path: url,
      password: password,
    );
    if (raw is! PostgresQueryProvider) {
      throw DatabaseException(
        'The registered engine returned a non-Postgres provider '
        '(${raw.runtimeType}). PgDb requires '
        'PostgresQueryProvider.',
        cause: raw.runtimeType,
      );
    }
    final PostgresQueryProvider provider = raw;
    final DbContext ctx = _PostgresContext(
      provider,
      entityMetas: entityMetas,
    );
    final PgDb db = PgDb._(provider, ctx);
    if (autoMigrate && entityMetas.isNotEmpty) {
      // Run the auto-migrator. The auto-
      // migrator is a no-op if the schema is
      // already in sync with the entity list.
      await db.runAutoMigrations();
    }
    return db;
  }

  /// Closes the underlying connection and
  /// releases the engine's resources. After
  /// this call, [provider] is unusable.
  Future<void> close() async {
    await _provider.disposeAsync();
  }

  /// Runs the auto-migrator against the
  /// currently registered entity list.
  ///
  /// The auto-migrator lives in d_rocket core
  /// (`orm/auto_migration/auto_migrator.dart`)
  /// and is engine-agnostic. The engine is
  /// responsible for ensuring the schema_state
  /// table exists before the migrator runs.
  Future<AutoMigrationResult> runAutoMigrations() async {
    final _PostgresContext ctx = _context as _PostgresContext;
    if (ctx._entityMetas.isEmpty) {
      return AutoMigrationResult(
        applied: const <SchemaDiff>[],
        unsafe: const <SchemaDiff>[],
        snapshot: SchemaSnapshot(
          version: 1,
          tables: const <SchemaTable>[],
        ),
      );
    }
    final AutoMigrator migrator = AutoMigrator(
      provider: _provider,
      entityMetas: ctx._entityMetas,
    );
    return migrator.run();
  }

  /// Returns the pending schema diff (the
  /// changes that would be applied by the
  /// auto-migration system) WITHOUT applying
  /// them. Useful for logging, dry-runs, and
  /// CI checks.
  Future<List<SchemaDiff>> pendingSchemaDiff() async {
    final _PostgresContext ctx = _context as _PostgresContext;
    if (ctx._entityMetas.isEmpty) {
      return const <SchemaDiff>[];
    }
    final AutoMigrator migrator = AutoMigrator(
      provider: _provider,
      entityMetas: ctx._entityMetas,
    );
    return migrator.computePendingDiff();
  }
}

/// The Postgres-engine [DbContext] subclass.
/// Mirrors `_SqliteRocketContext` in
/// d_rocket_engine_sqlite.
class _PostgresContext extends DbContext {
  _PostgresContext(
    this._provider, {
    List<EntityMeta> entityMetas = const <EntityMeta>[],
  }) {
    // The Postgres engine does NOT wire a
    // SyncQueueStore at open time. The
    // persistent sync queue would need a
    // Postgres-flavoured DDL (`CREATE TABLE
    // IF NOT EXISTS ... WITH (fillfactor=90)`)
    // and the existing d_rocket
    // SyncQueueStore emits SQLite DDL.
    // We leave queueStore as null; the user
    // can wire their own implementation if
    // they need the sync queue.
    _entityMetas.addAll(entityMetas);
  }

  final PostgresQueryProvider _provider;
  final List<EntityMeta> _entityMetas = <EntityMeta>[];

  /// helper: the list of [EntityMeta]s passed
  /// to the constructor. Used by the auto-
  /// migrator (which the [PgDb] calls via
  /// `db.runAutoMigrations()` /
  /// `db.pendingSchemaDiff()`).
  List<EntityMeta> get entityMetas =>
      List<EntityMeta>.unmodifiable(_entityMetas);

  @override
  AsyncQueryProvider? get asyncProvider => _provider;

  @override
  EntityMeta entityMetaFor<T>() {
    return EntityRegistry.metaFor(T);
  }

  @override
  DbSet<T> createDbSet<T>(EntityMeta Function() m) {
    // The DbSet constructor requires sync
    // callbacks (for the back-compat path).
    // The async path is the default — we
    // attach the Postgres provider via
    // `attachAsyncProvider`. The sync
    // callbacks throw because the user is
    // expected to use `*Async_` methods.
    return DbSet<T>(
      metaAccessor: m,
      tracker: changeTracker,
      execute: (String sql, List<Object?> binds) {
        throw DatabaseException(
          'The Postgres engine is async-only. Use the '
          '`*Async_` methods on the DbSet '
          '(toListAsync_, findByIdAsync_, etc.). The '
          'sync API throws on Postgres because the '
          'wire-protocol client has no synchronous '
          'entry point.',
        );
      },
      select: (String sql, List<Object?> binds) {
        throw DatabaseException(
          'The Postgres engine is async-only. Use the '
          '`*Async_` methods on the DbSet '
          '(toListAsync_, findByIdAsync_, etc.).',
        );
      },
      lastInsertRowId: () {
        throw DatabaseException(
          'The Postgres engine does not support '
          'lastInsertRowId. Use INSERT ... RETURNING '
          'and read the id from the result rows.',
        );
      },
    )..attachAsyncProvider(_provider);
  }
}
