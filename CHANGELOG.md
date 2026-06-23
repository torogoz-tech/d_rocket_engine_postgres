# Changelog

All notable changes to `d_rocket_engine_postgres`
are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] — 2026-06-17

Initial release. The second engine package
in the d_rocket 2.0 multi-engine architecture.

* **`PostgresEngine` (`DbEngine` contract).**
  The registry slot where the engine plugs in.
  `name = 'postgres'`, `isAvailable = true`
  (pure Dart, no native lib to load).

* **`PostgresQueryProvider`
  (`AsyncQueryProvider` contract).** The
  wire-protocol client (`package:postgres`)
  wrapped in the d_rocket async interface.
  Supports `selectAsync`, `executeAsync`,
  `beginTransactionAsync`, `commitAsync`,
  `rollbackAsync`, `disposeAsync`.

* **`PgDb` facade + `_PostgresContext`
  (`DbContext`).** The user-facing facade for
  the Postgres engine. Mirrors the SQLite
  engine's `Db` class.

* **`dRocketPostgres()` registration helper.**
  The single entry point the consumer calls
  once at app startup.

* **Auto-migrator integration.** The
  `d_rocket` core's auto-migrator is
  engine-agnostic; this package just wires
  the `entityMetas` and exposes
  `db.runAutoMigrations()` /
  `db.pendingSchemaDiff()`.

* **`?`-placeholder auto-rewrite to `$N`.**
  The dev can use `?` placeholders in raw
  SQL; the provider rewrites them to the
  Postgres wire-protocol `$1, $2, ...` form
  on every `executeAsync` / `selectAsync`
  call.

* **Error wrapping.** All wire-protocol
  exceptions are caught and re-raised as
  `DatabaseException` (in d_rocket core) with
  the original `PgException` as the `cause`.
  The `ServerException.code` (Postgres SQL
  state) is included in the `message` for
  easier diagnosis.

* **`lastInsertRowIdAsync` throws with a
  clear message.** Postgres has no
  per-connection "last insert id"; the
  standard way is the `INSERT ... RETURNING
  <pk>` clause. The provider throws
  `DatabaseException` with a pointer to the
  RETURNING pattern.

* **Test helper with `TEST_PG_URL` skip.** The
  test suite is gated on the `TEST_PG_URL`
  env var; tests are skipped (not failed) in
  environments without a Postgres instance.

## Deferred to 2.1 (and beyond)

* **SQL LINQ `Queryable<T>`** — the
  `db.set<T>().where(...)` extension. 90% of
  the SQLite translator's logic is
  reusable; the remaining 10% (placeholder
  conversion, RETURNING clause, SERIAL /
  BIGSERIAL handling) is a 2.1 feature.
* **Built-in connection pooling** — use
  `package:postgres_pool` directly in 2.0.
* **`LISTEN` / `NOTIFY` reactive queries** —
  shipped in 2.0.0 (via `PostgresListenNotify`,
  the pure-Dart wire-protocol client). Native
  async LISTEN via libpq FFI is a 2.2 feature
  (the 2.0 implementation polls the socket for
  notifications, which is fine for typical
  workloads but blocks the connection under
  burst traffic).
* **libpq FFI variant** — for cases that
  need libpq's extra features (COPY,
  async LISTEN).
