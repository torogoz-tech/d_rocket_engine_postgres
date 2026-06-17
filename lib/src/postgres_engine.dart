/// The PostgreSQL engine for d_rocket 2.0.
///
/// Implements d_rocket's [DbEngine] contract over
/// the Postgres wire protocol. Register it once
/// at app startup with `dRocketPostgres()` and
/// the `PgDb` facade lights up.
///
/// ## Wire-protocol client
///
/// We use the `package:postgres` client (by
/// stablekernel), a pure-Dart implementation of
/// the Postgres v3 wire protocol over TCP. This
/// is **not** an FFI binding to libpq — the
/// README has a section explaining the trade-off
/// (wire protocol = portable, FFI = more features
/// like libpq's COPY protocol and async LISTEN
/// via `PQconsumeInput`). For 2.0 the wire-
/// protocol client covers the 99% case and works
/// on every platform Dart supports, including
/// Flutter on Android, iOS, and Web (no
/// libpq.so to bundle).
///
/// ## Connection string format
///
/// The [open] `path` parameter is a Postgres
/// connection URL of the form
/// `postgres://user:pass@host:port/dbname?sslmode=require`,
/// or just a DSN-formatted string. The
/// `package:postgres` `Connection.openFromUrl`
/// accepts both. The `password` parameter is a
/// fallback when the URL does not embed the
/// password (the user is read from the URL; if
/// the URL has no password, the `password`
/// parameter is used).
library;

import 'package:d_rocket/d_rocket.dart';

import 'pg/query_provider.dart';

/// The Postgres-backed [DbEngine] implementation.
class PostgresEngine implements DbEngine {
  const PostgresEngine();

  @override
  String get name => 'postgres';

  @override
  bool get isAvailable {
    // The `package:postgres` client is pure Dart
    // and runs on every platform. There is no
    // native binding to load, so the engine is
    // always "available" from the perspective of
    // the registry. The actual connection is
    // attempted at `open()` time and surfaces
    // any network / authentication failure as
    // a [DatabaseException] with a clear message.
    return true;
  }

  @override
  Future<AsyncQueryProvider> open({
    String? path,
    String? password,
    Object? encryptionConfig,
  }) async {
    // Postgres has no equivalent to SQLite's
    // file path. The [path] is the connection
    // string (`postgres://user:pass@host:port/db`).
    // The [password] is only used if the
    // connection string has no embedded password.
    // We ignore [encryptionConfig] — Postgres
    // has no column-level encryption analogous
    // to SQLCipher. For transport-level
    // encryption, use `?sslmode=require` in
    // the connection URL.
    if (path == null) {
      throw DatabaseException(
        'The Postgres engine requires a connection string '
        'as the `path` parameter. Pass the full URL, e.g. '
        "'postgres://user:pass@host:5432/dbname', or just "
        'the host/port/db. See the package README for the '
        'connection string format.',
      );
    }
    final provider = await PostgresQueryProvider.openFromUrl(
      url: path,
      password: password,
    );
    return provider;
  }
}
