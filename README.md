# d_rocket_engine_postgres

<p align="center">
  <img src="https://coresg-normal.trae.ai/api/ide/v1/text_to_image?prompt=A%20modern%2C%20sleek%20rocket%20launching%20through%20a%20stylized%20database%20disk%2C%20with%20a%20trail%20of%20code%20streams%20representing%20six%20layers%20%28serialization%2C%20REST%2C%20LINQ%2C%20ORM%2C%20sync%2C%20realtime%29%2C%20deep%20navy%20blue%20to%20electric%20cyan%20gradient%2C%20geometric%20hexagonal%20accents%2C%20professional%20Dart%20framework%20brand%20banner%2C%20clean%20composition%2C%20no%20text&image_size=landscape_16_9" alt="d_rocket_engine_postgres banner" width="100%">
</p>

> **PostgreSQL engine for [d_rocket 2.0](https://pub.dev/packages/d_rocket).**
> The runtime that powers the `PgDb` facade over the
> Postgres wire protocol. Lockstep with
> [`d_rocket_engine_sqlite`](../d_rocket_engine_sqlite/):
> the second of three engine packages that ship in
> 2.0 (SQLite, Postgres, libsql_wasm).

`d_rocket` is engine-agnostic. Each database
backend (SQLite, Postgres, libsql_wasm, …)
ships as its own `d_rocket_engine_*` package.
This package is the **Postgres** implementation.

## When to use this package

| Backend | Use case |
| --- | --- |
| `d_rocket_engine_sqlite` | Local / single-user apps. Embedded engine. ~500KB binary. |
| `d_rocket_engine_postgres` | Multi-user / multi-machine apps. Server-side backend. |
| `d_rocket_engine_libsql_wasm` | Browser / edge runtime. WASM engine. (Phase 4) |

For a single-player or single-user app,
**`d_rocket_engine_sqlite` is the right choice** —
the binary is smaller and the engine has no
network round-trips. For a multi-user / server-side
app, **`d_rocket_engine_postgres` is the right
choice** — Postgres handles concurrent writers,
replication, and large datasets.

## Status: 2.0.0 MVP

| Feature | 2.0.0 (this release) | 2.1 (planned) |
| --- | --- | --- |
| `PostgresEngine` (`DbEngine`) | ✅ | — |
| `PostgresQueryProvider` (`AsyncQueryProvider`) | ✅ | — |
| `PgDb` facade + `DbContext` | ✅ | — |
| `dRocketPostgres()` registration | ✅ | — |
| Auto-migrator (via d_rocket core) | ✅ | — |
| `BEGIN` / `COMMIT` / `ROLLBACK` | ✅ | — |
| `?`-placeholder auto-rewrite to `$N` | ✅ | — |
| Error wrapping (`DatabaseException` + cause) | ✅ | — |
| `INSERT ... RETURNING` codegen support | ✅ (raw SQL only) | Full LINQ |
| SQL LINQ `Queryable<T>` (`db.set<T>().where(...)`) | ❌ (deferred) | ✅ |
| Connection pooling | ❌ (use `postgres_pool` directly) | Built-in pool |
| `LISTEN` / `NOTIFY`-based reactive queries | ✅ (raw, no async libpq) | ✅ |
| FFI bindings to libpq | ❌ (wire protocol only) | Maybe |

## What you can do in 2.0.0

* Connect to any Postgres 9.6+ instance over TCP.
* Run raw SQL (SELECT / INSERT / UPDATE / DELETE) with
  `?`-style placeholders (auto-rewritten to `$N`).
* Use the engine-agnostic `DbContext` for
  migrations, change tracking, and the
  auto-migrator (via `db.context`).
* Open the connection from a URL or from
  individual host/port/database/username/password.
* Use the engine's underlying `Connection` (via
  `db.provider.connection`) for advanced cases
  (COPY, LISTEN/NOTIFY, etc.).

## What you can NOT do in 2.0.0 (deferred to 2.1)

* The SQL LINQ `Queryable<T>` (the
  `db.set<T>().where(...)` extension). For
  2.0.0, use `db.provider.selectAsync(...)` and
  `db.provider.executeAsync(...)` directly. The
  `Queryable<T>` is a 2.1 feature; the Postgres
  dialect shares 90% of the SQLite translator's
  logic, but the remaining 10% (placeholder
  conversion, RETURNING clause, SERIAL/BIGSERIAL
  handling, parameter types) is a 2.1
  feature.
* Built-in connection pooling. For 2.0.0, use
  `package:postgres_pool` directly and wrap each
  pooled connection in a `PostgresQueryProvider`.
  The d_rocket engine will provide a pooled
  facade in 2.1.

## Wire protocol vs libpq FFI

This package uses `package:postgres` (by
stablekernel), a **pure-Dart** implementation
of the Postgres v3 wire protocol over TCP. It
is **not** an FFI binding to libpq. The
trade-off:

| | Wire protocol (`postgres`) | libpq FFI |
| --- | --- | --- |
| Native lib to bundle | None (pure Dart) | `libpq.so` / `libpq.dylib` |
| Works on Flutter Web | ✅ | ❌ |
| Works on Android / iOS | ✅ | ✅ (with extra setup) |
| Bulk `COPY` support | Limited (extended query only) | Full |
| `LISTEN` / `NOTIFY` async | Polling | Native (PQconsumeInput) |
| Server-side cursors | Partial | Full |
| Network transport | TCP only | TCP / Unix socket |

For 2.0.0 the wire protocol covers the 99%
case and works on every platform Dart
supports (including Flutter on Android, iOS,
and Web). A future 2.x release may add a
parallel `libpq` FFI binding for cases that
need libpq's extra features.

## Usage

### pubspec.yaml

```yaml
dependencies:
  d_rocket: ^2.0.0
  d_rocket_engine_postgres: ^2.0.0
```

### main.dart

```dart
import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';

Future<void> main() async {
  // Required: register the Postgres engine
  // once at app startup. Without this call,
  // `PgDb.open` throws a clear "no engine
  // registered" error.
  dRocketPostgres();
  initializeD();

  final db = await PgDb.open(
    url: 'postgres://app:secret@localhost:5432/mydb',
  );
  try {
    // Raw SQL with `?` placeholders.
    // (The provider auto-rewrites them to $N.)
    final rows = await db.provider.selectAsync(
      'SELECT id, name FROM users WHERE active = ?',
      [true],
    );
    print(rows);
  } finally {
    await db.close();
  }
}
```

### Opening a connection

```dart
// From a URL.
final db = await PgDb.open(
  url: 'postgres://app:secret@localhost:5432/mydb',
);

// From a URL with no embedded password.
final db = await PgDb.open(
  url: 'postgres://app@localhost:5432/mydb',
  password: 'secret',
);

// From individual parameters.
final provider = await PostgresQueryProvider.open(
  host: 'localhost',
  port: 5432,
  database: 'mydb',
  username: 'app',
  password: 'secret',
);
```

### Using the auto-migrator

```dart
dRocketPostgres();
initializeD();

final db = await PgDb.open(
  url: 'postgres://app:secret@localhost:5432/mydb',
  entityMetas: [bookMeta, authorMeta],
  autoMigrate: true, // runs the auto-migrator
);
```

The auto-migrator lives in d_rocket core and is
engine-agnostic. It creates the `schema_state`
table on first run and applies the safe diffs
(create column, drop column, etc.).

## Topics & search keywords

`postgres` `postgresql` `d_rocket` `engine`
`engine-agnostic` `wire-protocol` `libpq` `orm`
`pubspec` `flutter` `dart`

## License

MIT. See [LICENSE](LICENSE).

## Author

**Abner Velasco** — *Arquitecto de Soluciones*

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Abner%20Velasco-0A66C2?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/abnervelasco/)
