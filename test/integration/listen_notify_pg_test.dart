// 2.0.0 — Postgres integration tests for
// the LISTEN/NOTIFY pipeline (Phase 8.10).
//
// These tests connect to a real Postgres
// and exercise the full
// trigger → NOTIFY → LISTEN → DbChangeEvent
// flow end-to-end.
//
// Connection parameters are read from
// environment variables:
//
//   POSTGRES_HOST   (default: localhost)
//   POSTGRES_PORT   (default: 5433)
//   POSTGRES_USER   (default: ai_user)
//   POSTGRES_PASS   (default: <none>)
//   POSTGRES_DB     (default: ai_knowledge)
//   POSTGRES_SSL    (default: disable)
//
// The defaults match the
// `pgvector/pgvector:pg17` container
// running on the d_rocket workstation
// (port 5433 to avoid colliding with
// Postgres.app on 5432). On CI / other
// hosts, set the env vars to point at
// the appropriate instance. If no
// Postgres is reachable, the tests
// SKIP cleanly (no failure).
//
// To run manually:
//
//   # default (localhost:5433):
//   dart test test/integration/listen_notify_pg_test.dart
//
//   # custom host:
//   POSTGRES_HOST=db.internal POSTGRES_PORT=5432 \
//   POSTGRES_USER=app POSTGRES_PASS=secret \
//   POSTGRES_DB=app_test POSTGRES_SSL=require \
//     dart test test/integration/listen_notify_pg_test.dart
//
// This file lives in `test/integration/`
// so the standard `dart test` invocation
// (which auto-discovers `test/*.dart`)
// does NOT run it. The CI step that runs
// it (`tool/ci.sh integration`)
// walks the integration dir explicitly.

import 'dart:async';
import 'dart:io';

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// Reads the Postgres connection
/// parameters from the environment.
/// Falls back to the d_rocket workstation
/// defaults (the `pgvector/pgvector:pg17`
/// container on localhost:5433).
class PgEnv {
  static String host =
      Platform.environment['POSTGRES_HOST'] ?? 'localhost';
  static int port =
      int.parse(Platform.environment['POSTGRES_PORT'] ?? '5433');
  static String user =
      Platform.environment['POSTGRES_USER'] ?? 'ai_user';
  static String pass =
      Platform.environment['POSTGRES_PASS'] ??
          'Ep8y4iR92Gj06q4m5AtbM9Dff9DWnOwMbEjTqDFBPKg=';
  static String db =
      Platform.environment['POSTGRES_DB'] ?? 'ai_knowledge';
  static String ssl =
      Platform.environment['POSTGRES_SSL'] ?? 'disable';

  static Endpoint get endpoint => Endpoint(
        host: host,
        port: port,
        database: db,
        username: user,
        password: pass,
      );

  /// Build a `postgres://user:pass@host:port/db`
  /// URL for `PostgresPool.open(url: ...)`.
  /// `package:postgres`'s `Endpoint` does
  /// NOT have a `toString()` that produces
  /// a URL, so we build it ourselves.
  ///
  /// SSL is disabled by default — the
  /// workstation's `pgvector` container
  /// doesn't speak TLS, and the `package:
  /// postgres` client refuses to connect
  /// without an explicit `sslmode=disable`.
  /// Set `POSTGRES_SSL=require` to opt
  /// back in (CI typically provides a
  /// TLS-terminating proxy).
  static String get url {
    final String encoded = Uri.encodeComponent(pass);
    return 'postgres://$user:$encoded@$host:$port/$db?sslmode=$ssl';
  }

  static SslMode get sslMode =>
      ssl == 'require' ? SslMode.require : SslMode.disable;
}

/// Probes the Postgres connection once.
/// Returns true if reachable, false
/// otherwise. The probe is a SELECT 1
/// (the cheapest possible query).
Future<bool> _pgReachable(Endpoint endpoint, SslMode sslMode) async {
  try {
    final conn = await Connection.open(
      endpoint,
      settings: ConnectionSettings(sslMode: sslMode),
    );
    final r = await conn.execute('SELECT 1');
    await conn.close();
    return r.isNotEmpty;
  } on Object {
    return false;
  }
}

/// Splits a multi-statement SQL script
/// into individual statements while
/// respecting:
///
/// 1. Single-quoted string literals
///    (no `;` splits inside `'...'`).
/// 2. Dollar-quoted string literals
///    (`$tag$ ... $tag$`, including the
///    empty-tag `$$ ... $$` form used by
///    PL/pgSQL function bodies).
/// 3. Line comments (`-- ...`).
/// 4. Block comments (`/* ... */`).
///
/// Returns a list of non-empty, trimmed
/// statements ready to be passed to
/// `Connection.execute()` (which only
/// accepts single statements under the
/// prepared-statement protocol).
List<String> _splitSqlScript(String script) {
  final List<String> out = <String>[];
  final StringBuffer buf = StringBuffer();
  String? dollarTag;
  bool inSingle = false;
  int i = 0;
  while (i < script.length) {
    final String c = script[i];
    // Block comment
    if (!inSingle && dollarTag == null &&
        c == '/' &&
        i + 1 < script.length &&
        script[i + 1] == '*') {
      final int end = script.indexOf('*/', i + 2);
      if (end == -1) {
        buf.write(script.substring(i));
        i = script.length;
        break;
      }
      buf.write(script.substring(i, end + 2));
      i = end + 2;
      continue;
    }
    // Line comment
    if (!inSingle && dollarTag == null &&
        c == '-' &&
        i + 1 < script.length &&
        script[i + 1] == '-') {
      final int nl = script.indexOf('\n', i);
      final int end = nl == -1 ? script.length : nl;
      buf.write(script.substring(i, end));
      i = end;
      continue;
    }
    // Dollar-quoted string
    if (!inSingle && c == r'$') {
      int j = i + 1;
      while (j < script.length &&
          (RegExp(r'[A-Za-z0-9_]').hasMatch(script[j]))) {
        j++;
      }
      final String tag = script.substring(i, j);
      if (j < script.length && script[j] == r'$') {
        if (dollarTag == null) {
          dollarTag = tag;
          buf.write(script.substring(i, j + 1));
          i = j + 1;
          continue;
        } else if (dollarTag == tag) {
          buf.write(script.substring(i, j + 1));
          i = j + 1;
          dollarTag = null;
          continue;
        }
      }
      buf.write(c);
      i++;
      continue;
    }
    // Single-quoted string
    if (dollarTag == null && c == "'") {
      inSingle = !inSingle;
      buf.write(c);
      i++;
      continue;
    }
    // Statement separator
    if (!inSingle && dollarTag == null && c == ';') {
      final String stmt = buf.toString().trim();
      if (stmt.isNotEmpty) out.add(stmt);
      buf.clear();
      i++;
      continue;
    }
    buf.write(c);
    i++;
  }
  final String tail = buf.toString().trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}

/// Executes a multi-statement SQL script
/// on [conn], one statement at a time
/// (the only way under `package:postgres`'s
/// prepared-statement protocol).
Future<void> _executeScript(Connection conn, String script) async {
  for (final String stmt in _splitSqlScript(script)) {
    await conn.execute(stmt);
  }
}

Future<Connection> openConn() => Connection.open(
      PgEnv.endpoint,
      settings: ConnectionSettings(sslMode: PgEnv.sslMode),
    );

void main() {
  bool pgOk = false;

  setUpAll(() async {
    pgOk = await _pgReachable(PgEnv.endpoint, PgEnv.sslMode);
  });

  test('installNotifyTriggersSql + LISTEN → NOTIFY roundtrip', () async {
    if (!pgOk) {
      markTestSkipped(
        'Postgres not reachable at '
        '${PgEnv.host}:${PgEnv.port} — skipping',
      );
      return;
    }

    // 1. Create a minimal users table +
    //    install the NOTIFY triggers.
    final setup = await openConn();
    await setup.execute('DROP TABLE IF EXISTS d_rocket_integ_users');
    await setup.execute('''
      CREATE TABLE d_rocket_integ_users (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL
      )
    ''');
    await _executeScript(
      setup,
      installNotifyTriggersSql('d_rocket_integ_users'),
    );
    await setup.close();

    // 2. Open the pool + a listener.
    final pool = await PostgresPool.open(
      url: PgEnv.url,
      config: PoolConfig(min: 1, max: 4),
    );
    final listener = await PostgresListenNotify.open(
      pool: pool,
      table: 'd_rocket_integ_users',
    );

    // 3. Insert a row on a different
    //    connection and expect the
    //    listener to fire.
    final inserter = await openConn();
    final completer = Completer<DbChangeEvent>();
    final sub = listener.stream.listen(
      (e) {
        if (!completer.isCompleted) completer.complete(e);
      },
    );
    await inserter.execute(
      "INSERT INTO d_rocket_integ_users (name) "
      "VALUES ('alice')",
    );
    final ev = await completer.future.timeout(
      const Duration(seconds: 10),
    );
    expect(ev.op, equals(DbChangeOp.insert));
    expect(ev.primaryKey, isNotNull);

    // 4. UPDATE; expect op=update.
    final completer2 = Completer<DbChangeEvent>();
    final sub2 = listener.stream
        .where((e) => e.op == DbChangeOp.update)
        .listen((e) {
      if (!completer2.isCompleted) completer2.complete(e);
    });
    await inserter.execute(
      "UPDATE d_rocket_integ_users SET name = 'bob' "
      "WHERE name = 'alice'",
    );
    final ev2 = await completer2.future.timeout(
      const Duration(seconds: 10),
    );
    expect(ev2.op, equals(DbChangeOp.update));

    // 5. DELETE; expect op=delete + row=null.
    final completer3 = Completer<DbChangeEvent>();
    final sub3 = listener.stream
        .where((e) => e.op == DbChangeOp.delete)
        .listen((e) {
      if (!completer3.isCompleted) completer3.complete(e);
    });
    await inserter.execute(
      "DELETE FROM d_rocket_integ_users "
      "WHERE name = 'bob'",
    );
    final ev3 = await completer3.future.timeout(
      const Duration(seconds: 10),
    );
    expect(ev3.op, equals(DbChangeOp.delete));
    expect(ev3.row, isNull,
        reason: 'DELETE events drop the row payload');

    // 6. Cleanup.
    await sub.cancel();
    await sub2.cancel();
    await sub3.cancel();
    await listener.close();
    await inserter.close();
    await pool.disposeAsync();

    final cleanup = await openConn();
    await cleanup.execute(
      'DROP TABLE IF EXISTS d_rocket_integ_users',
    );
    await cleanup.close();
  });

  test('wide rows drop the row key', () async {
    if (!pgOk) {
      markTestSkipped(
        'Postgres not reachable at '
        '${PgEnv.host}:${PgEnv.port} — skipping',
      );
      return;
    }

    final setup = await openConn();
    await setup.execute(
      'DROP TABLE IF EXISTS d_rocket_integ_wide',
    );
    await setup.execute('''
      CREATE TABLE d_rocket_integ_wide (
        id BIGSERIAL PRIMARY KEY,
        body TEXT NOT NULL
      )
    ''');
    await _executeScript(
      setup,
      installNotifyTriggersSql('d_rocket_integ_wide'),
    );
    await setup.close();

    final pool = await PostgresPool.open(
      url: PgEnv.url,
      config: PoolConfig(min: 1, max: 4),
    );
    final listener = await PostgresListenNotify.open(
      pool: pool,
      table: 'd_rocket_integ_wide',
    );
    final inserter = await openConn();

    final completer = Completer<DbChangeEvent>();
    final sub = listener.stream.listen(
      (e) {
        if (!completer.isCompleted) completer.complete(e);
      },
    );

    // 8 KB string (well above the 7 KB
    // trigger threshold).
    final wide = 'x' * 8000;
    await inserter.execute(
      'INSERT INTO d_rocket_integ_wide (body) '
      "VALUES ('$wide')",
    );
    final ev = await completer.future.timeout(
      const Duration(seconds: 10),
    );
    expect(ev.op, equals(DbChangeOp.insert));
    expect(ev.row, isNull,
        reason: 'wide rows must drop the row key');

    await sub.cancel();
    await listener.close();
    await inserter.close();
    await pool.disposeAsync();

    final cleanup = await openConn();
    await cleanup.execute(
      'DROP TABLE IF EXISTS d_rocket_integ_wide',
    );
    await cleanup.close();
  });
}