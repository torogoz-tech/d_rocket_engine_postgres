// Shared test helpers for `d_rocket_engine_postgres`
// tests.
//
// The Postgres engine tests need a real Postgres
// instance. The test helper reads
// `TEST_PG_URL` (env var) and uses that as the
// connection string. If the env var is not set,
// the tests are marked as `skip` so the suite
// can run in CI environments that don't have
// Postgres available.
//
// The helper also registers the Postgres engine
// (and tears it down between tests) so the
// engine's contract tests are isolated.

library;

import 'dart:io';

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

/// The env var name for the test Postgres
/// connection URL. CI sets this to e.g.
/// `postgres://test:test@localhost:5432/d_rocket_test`.
const String kTestPgUrlEnv = 'TEST_PG_URL';

/// Returns the test Postgres connection URL.
/// Throws [StateError] if `TEST_PG_URL` is not
/// set; callers should use [testPgUrlOrSkip] in
/// tests so the test is marked as skipped in
/// environments without Postgres.
String get testPgUrl {
  final String? url = Platform.environment[kTestPgUrlEnv];
  if (url == null || url.isEmpty) {
    throw StateError(
      'TEST_PG_URL is not set. The d_rocket_engine_postgres '
      'test suite needs a real Postgres instance. Set '
      'TEST_PG_URL=postgres://user:pass@host:5432/db and '
      'rerun.',
    );
  }
  return url;
}

/// Returns the test Postgres connection URL,
/// or `null` if `TEST_PG_URL` is not set.
/// Test bodies should treat `null` as "skip".
String? get testPgUrlOrNull {
  final String? url = Platform.environment[kTestPgUrlEnv];
  if (url == null || url.isEmpty) return null;
  return url;
}

/// Convenience: returns a [Skip] expression for
/// use as the `skip` argument of `test()` /
/// `group()`. Returns `null` if `TEST_PG_URL`
/// is set (the test should run).
Object? get pgSkipReason {
  if (testPgUrlOrNull == null) {
    return 'TEST_PG_URL is not set; skipping Postgres integration test';
  }
  return null;
}

/// Registers the Postgres engine and resets the
/// registry between tests. Idempotent.
void setUpPostgres() {
  setUp(dRocketPostgres);
  tearDown(EngineRegistry.resetForTest);
}
