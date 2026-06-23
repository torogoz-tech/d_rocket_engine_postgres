/// 🚀 d_rocket_engine_postgres — PostgreSQL engine for d_rocket 2.0.
///
/// The runtime that powers the `PgDb` facade
/// of [d_rocket](https://pub.dev/packages/d_rocket)
/// over the Postgres wire protocol. The
/// `d_rocket` core is engine-agnostic; each
/// backend (SQLite, Postgres, libsql_wasm, …)
/// ships as its own `d_rocket_engine_*`
/// package. This package is the Postgres
/// implementation.
///
/// ## Usage
///
/// ```yaml
/// # pubspec.yaml
/// dependencies:
///   d_rocket: ^2.0.0
///   d_rocket_engine_postgres: ^2.0.0
/// ```
///
/// ```dart
/// import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
///
/// Future<void> main() async {
///   // Required: register the Postgres engine
///   // once at app startup. Without this call,
///   // `PgDb.open` throws a clear "no engine
///   // registered" error.
///   dRocketPostgres();
///   initializeD();
///
///   final db = await PgDb.open(
///     url: 'postgres://app:secret@localhost:5432/mydb',
///   );
///   try {
///     final rows = await db.provider.selectAsync(
///       'SELECT id, name FROM users WHERE active = $1',
///       [true],
///     );
///     print(rows);
///   } finally {
///     await db.close();
///   }
/// }
/// ```
///
/// ## What is included in 2.0.0
///
/// * `PostgresEngine` (the `DbEngine` contract).
/// * `PostgresQueryProvider` (the
///   `AsyncQueryProvider` implementation).
/// * `PgDb` facade + `_PostgresContext` (the
///   `DbContext` for migrations and change
///   tracking).
/// * `PostgresDialect` (the engine-specific
///   `SqlDialect` override: `STRPOS` for
///   `String.contains`, `jsonb_build_object`
///   for map literals; the `?` → `$N`
///   placeholder rewriting happens in
///   `PostgresQueryProvider`).
/// * `PostgresDbSetExtension` + `DbSetLinqExtension`
///   (the `db.set<T>().where(...).toListAsync_()`
///   flow). The engine is async-only; the legacy
///   sync methods (`toList_`, `count_`, …) throw
///   a clear error directing the user to the
///   `*Async_` variants.
/// * `dRocketPostgres()` registration helper.
/// * Auto-migrator integration (via the
///   `d_rocket` core's `auto_migration.dart`).
/// * Connection pooling (via `src/pg/pool.dart`).
///
/// ## What is NOT in 2.0.0 (deferred to 2.1)
///
/// * `groupBy` / `join` / `groupJoin` LINQ
///   operators (their return types are
///   SQLite-flavoured; the Postgres engine
///   would need its own
///   `PostgresGroupedQueryable` /
///   `PostgresJoinedQueryable`). For 2.0.0
///   the user can do joins via raw SQL on
///   `db.provider.selectAsync`.
/// * LISTEN/NOTIFY-based reactive queries
///   (a 2.2 feature).
///
/// ## Phase 8.9 (2.0.0): LISTEN/NOTIFY
///
/// The LISTEN/NOTIFY feature is INCLUDED
/// in 2.0.0 (not deferred to 2.2 anymore).
/// See `PostgresListenNotify` + the
/// `installNotifyTriggersSql` helper.
library;

import 'package:d_rocket/d_rocket.dart';

import 'src/postgres_engine.dart';

// Re-export d_rocket core so consumers can
// import everything they need from
// `d_rocket_engine_postgres`. The engine
// package is the canonical entry point for
// the Postgres-based stack; d_rocket core
// is the canonical entry point for the
// engine-agnostic layers (serialization,
// REST, sync, realtime).
export 'package:d_rocket/d_rocket.dart';

export 'src/pg/pg_dialect.dart';
export 'src/pg/pool.dart';
export 'src/pg/pool_config.dart';
export 'src/pg/query_provider.dart';
//: `src/pg/queryable.dart` is gone. The
// Postgres engine uses the engine-agnostic
// `Queryable<T>` from d_rocket core
// (re-exported by the d_rocket barrel).
// The engine only contributes the
// `PostgresDialect` (3-method dialect
// override) and the `PostgresQueryProvider`
// (wire-protocol client + `?` to `$N`
// rewrite).
export 'src/pgdb.dart';
export 'src/pgdb_set_extension.dart';
export 'src/postgres_engine.dart';
// 2.0.0 — LISTEN/NOTIFY reactive streams
// (Phase 8.9).
export 'src/listen_notify.dart';

/// Top-level registration helper. Call once
/// at app startup before any `PgDb.open` /
/// `PostgresQueryProvider.open` call.
/// Idempotent — calling it twice replaces
/// the previously registered engine with a
/// fresh `PostgresEngine` (the `EngineRegistry`
/// only holds one slot).
void dRocketPostgres() {
  EngineRegistry.register(const PostgresEngine());
}
