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
/// * `dRocketPostgres()` registration helper.
/// * Auto-migrator integration (via the
///   `d_rocket` core's `auto_migration.dart`).
///
/// ## What is NOT in 2.0.0 (deferred to 2.1)
///
/// * The SQL LINQ `Queryable<T>` (the
///   `db.set<T>().where(...)` extension). The
///   Postgres dialect shares 90% of the SQLite
///   translator's logic, but the remaining 10%
///   (placeholder conversion, RETURNING clause,
///   SERIAL/BIGSERIAL handling) is a 2.1
///   feature. For 2.0, use the `provider`'s
///   `selectAsync` / `executeAsync` directly.
/// * Connection pooling (use
///   `package:postgres_pool` directly in 2.0;
///   `d_rocket_engine_postgres` will provide a
///   pooled facade in 2.1).
/// * LISTEN/NOTIFY-based reactive queries
///   (a 2.2 feature).
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
