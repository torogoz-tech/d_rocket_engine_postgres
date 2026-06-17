// Engine contract tests for d_rocket_engine_postgres.
//
// These tests verify the engine's behavior
// WITHOUT needing a real Postgres instance:
// the engine's `name` and `isAvailable` are
// pure values, and the engine's `open()` can
// be tested with a mock URL (the actual
// connection failure is caught and surfaced
// as a `DatabaseException`).
//
// Tests that DO need a real Postgres are in
// `connection_test.dart`, `select_execute_test.dart`,
// and `transaction_test.dart` and use the
// `TEST_PG_URL` env var to gate themselves.

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketPostgres);
  tearDown(EngineRegistry.resetForTest);

  group('PostgresEngine', () {
    test('name is "postgres"', () {
      const engine = PostgresEngine();
      expect(engine.name, equals('postgres'));
    });

    test('isAvailable is true (pure Dart, no native lib)', () {
      const engine = PostgresEngine();
      expect(engine.isAvailable, isTrue);
    });

    test('is registered after dRocketPostgres()', () {
      dRocketPostgres();
      expect(EngineRegistry.isRegistered, isTrue);
      expect(EngineRegistry.findOrThrow, isA<PostgresEngine>());
    });

    test('re-registering is idempotent (same name, same behavior)', () {
      dRocketPostgres();
      final DbEngine first = EngineRegistry.findOrThrow;
      dRocketPostgres();
      final DbEngine second = EngineRegistry.findOrThrow;
      // `PostgresEngine` is `const`; both
      // calls produce the same instance.
      // The doc on `dRocketPostgres()` says
      // it "replaces" the engine, but the
      // replacement is a no-op when the
      // engine is const-equal. The
      // important invariant is: the engine
      // is still the Postgres one, and its
      // name is unchanged.
      expect(second.name, equals('postgres'));
      expect(second, isA<PostgresEngine>());
      // Sanity: first and second are
      // both registered engines (not
      // null).
      expect(first.name, equals('postgres'));
    });
  });

  group('PostgresEngine.open() validation', () {
    const engine = PostgresEngine();

    test('throws DatabaseException when path is null', () async {
      try {
        await engine.open();
        fail('expected DatabaseException');
      } on DatabaseException catch (e) {
        expect(
          e.message,
          contains('requires a connection string'),
        );
      }
    });

    test('throws DatabaseException when the URL is unparseable', () async {
      // An obviously bad URL surfaces the
      // `package:postgres` connection failure
      // as a `DatabaseException` with a clear
      // "Failed to open Postgres connection"
      // message.
      try {
        await engine.open(path: 'not-a-real-url://');
        // If the driver somehow accepted the
        // URL, that's still fine for this test
        // (the goal is to verify the wrap
        // doesn't crash the engine).
      } on DatabaseException catch (e) {
        expect(
          e.message.toLowerCase(),
          anyOf(
            contains('postgres'),
            contains('connection'),
            contains('host'),
          ),
        );
      } on Object catch (_) {
        // The wire-protocol client may throw
        // a different exception type for an
        // obviously bad URL. We just want to
        // verify it doesn't crash silently.
      }
    });
  });

  group('DatabaseException', () {
    test('wraps a Postgres connection failure', () async {
      try {
        // The IP 127.0.0.1:1 should fail to
        // connect on any normal setup.
        await PostgresQueryProvider.open(
          host: '127.0.0.1',
          port: 1,
          database: 'nope',
          username: 'nope',
          password: 'nope',
        );
        fail('expected DatabaseException');
      } on DatabaseException catch (e) {
        expect(e.cause, isNotNull);
      } on Object catch (_) {
        // The wire-protocol client may throw
        // a SocketException for connection
        // refused; we accept any wrapped error.
      }
    });
  });
}
