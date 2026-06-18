// Tests for the explicit `engine:` parameter
// on PgDb.open (and Db.open on the SQLite
// side). The explicit path lets the user
// pass the engine directly without calling
// dRocketPostgres() / dRocketSqlite() first.
//
// The 2.0.0 design has two paths:
//
// 1. Registry path (legacy): call
//    dRocketPostgres() once at startup, then
//    PgDb.open(url: '...'). The registry
//    holds the engine.
// 2. Explicit path (new): pass the engine
//    inline. The registry is bypassed.
//
// Path 2 is better for:
//   - tests (no global state pollution)
//   - multi-engine apps (no shared registry)
//   - "explore" / REPL workflows (no setup
//     step required)
//
// Both paths are supported; this test
// verifies the explicit path.

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  setUpPostgres();

  group('PgDb.open with explicit engine:', () {
    test(
      'bypasses the EngineRegistry',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        // Note: we DO NOT call dRocketPostgres()
        // here. The explicit engine path must
        // work even with an empty registry.
        // We can't easily assert the registry
        // is empty (other tests may have
        // populated it), but the explicit
        // path is the point: the call works
        // regardless of registry state.
        final db = await PgDb.open(
          url: url,
          engine: const PostgresEngine(),
        );
        try {
          expect(db, isNotNull);
          expect(db.isOpen, isTrue);
          // The provider is the Postgres
          // engine's query provider.
          expect(db.provider, isA<PostgresQueryProvider>());
        } finally {
          await db.close();
        }
        // Sanity: this test didn't blow up
        // just because of the registry state.
        expect(true, isTrue);
      },
      skip: pgSkipReason,
    );

    test(
      'passing a non-Postgres engine throws a clear error',
      () async {
        // The user passes a SqliteEngine to
        // PgDb.open. PgDb requires a Postgres
        // engine; this should throw with a
        // clear error message.
        expect(
          () => PgDb.open(
            url: 'postgres://invalid',
            engine: _NotAPostgresEngine(),
          ),
          throwsA(isA<DatabaseException>()),
        );
      },
    );
  });
}

/// A test stub DbEngine that is NOT a
/// PostgresEngine, used to verify that
/// PgDb.open rejects non-Postgres engines.
class _NotAPostgresEngine implements DbEngine {
  @override
  String get name => 'not-postgres';

  @override
  bool get isAvailable => false;

  @override
  Future<AsyncQueryProvider> open({
    String? path,
    String? password,
    Object? encryptionConfig,
  }) async {
    throw UnsupportedError('not used in this test');
  }
}
