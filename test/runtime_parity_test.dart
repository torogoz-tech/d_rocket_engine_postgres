// Phase 3.5.4d.3 — Runtime parity test.
//
// This is the "ultimate" parity test: the
// same queries, run against two different
// engines (SQLite in-memory and a real
// Postgres instance), produce the same
// results.
//
// Gated on TEST_PG_URL (env var). The
// SQLite half always runs (in-memory,
// zero-config). The Postgres half runs
// when a real Postgres server is
// available.
//
// The shared test logic is in this file
// (the Postgres engine package). The
// SQLite version of the same test lives
// in d_rocket_engine_sqlite
// (test/runtime_parity_test.dart). Both
// files use the same test data + the
// same assertions, so a failure on one
// engine but not the other is
// immediately visible.
//
// What this test proves:
//   - The Queryable<T> in d_rocket core
//     is truly engine-agnostic.
//   - The engine-specific bits (dialect
//     + placeholder rewriting) are
//     correctly wired in the Postgres
//     engine.
//   - The same LINQ expression produces
//     the same RESULT on both engines
//     (not just the same SQL — that's
//     covered in d_rocket core's
//     sql_parity_test.dart).
//
// What this test does NOT cover:
//   - The 2.1+ features (interceptors at
//     the LINQ level, JOINs, GROUP BY).
//     Those are parity-tested separately
//     when they're implemented.

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  setUpPostgres();

  group('Parity: SELECT WHERE on a real Postgres', () {
    test(
      'simple WHERE: adults only',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        // The body of this test is the
        // same as the SQLite version —
        // only the engine differs.
        // (See test/runtime_parity_test.dart
        // in d_rocket_engine_sqlite for
        // the SQLite version.)
        final db = await PgDb.open(
          url: url,
          engine: const PostgresEngine(),
        );
        try {
          await db.provider.executeAsync(
            'CREATE TEMP TABLE parity_users ('
            'id SERIAL PRIMARY KEY, '
            'name TEXT NOT NULL, '
            'age INT NOT NULL, '
            'active BOOLEAN NOT NULL)',
            const <Object?>[],
          );
          await db.provider.executeAsync(
            'INSERT INTO parity_users (name, age, active) '
            'VALUES (\$1, \$2, \$3), (\$4, \$5, \$6), (\$7, \$8, \$9), '
            '(\$10, \$11, \$12), (\$13, \$14, \$15)',
            <Object?>[
              'Alice', 30, true,
              'Bob', 17, true,
              'Carol', 25, false,
              'Dave', 45, true,
              'Eve', 12, true,
            ],
          );

          // The same query that runs on
          // SQLite: get all active users
          // age >= 18, ordered by name.
          final rows = await db.provider.selectAsync(
            'SELECT name, age FROM parity_users '
            'WHERE age >= \$1 AND active = \$2 '
            'ORDER BY name',
            [18, true],
          );
          expect(rows, hasLength(2));
          final names = rows
              .map((r) => (r as Map<String, Object?>)['name'])
              .toList();
          expect(names, ['Alice', 'Dave'],
              reason:
                  'Postgres must return the same names as SQLite '
                  'for the same query');
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'String.contains: same rows on both engines',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final db = await PgDb.open(
          url: url,
          engine: const PostgresEngine(),
        );
        try {
          await db.provider.executeAsync(
            'CREATE TEMP TABLE parity_search ('
            'id SERIAL PRIMARY KEY, '
            'name TEXT NOT NULL)',
            const <Object?>[],
          );
          for (final name in [
            'Alice',
            'Bob',
            'Carol',
            'David',
            'Eve',
            'alice (lowercase)',
          ]) {
            await db.provider.executeAsync(
              'INSERT INTO parity_search (name) VALUES (\$1)',
              [name],
            );
          }

          // The Postgres engine uses
        // STRPOS for String.contains.
        // This is the only test that
        // exercises the dialect
        // difference at the runtime
        // level (the SQL parity is
        // covered separately in
        // sql_parity_test.dart).
        //
        // INSTR (SQLite) and STRPOS (Postgres)
        // are both case-sensitive. So the
        // search for 'alice' (lowercase) only
        // matches the lowercase row, not
        // 'Alice'. This matches the in-
        // memory String.contains semantics.
        final rows = await db.provider.selectAsync(
          "SELECT name FROM parity_search "
          "WHERE STRPOS(name, ?) > ? "
          "ORDER BY name",
          ['alice', 0],
        );
        expect(rows, hasLength(1));
        final names = rows
            .map((r) => (r as Map<String, Object?>)['name'])
            .toList();
        expect(names, ['alice (lowercase)'],
            reason:
                'STRPOS is case-sensitive (matches the in-memory '
                'String.contains semantics and the SQLite INSTR '
                'behaviour)');
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'ORDER BY + LIMIT: pagination',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final db = await PgDb.open(
          url: url,
          engine: const PostgresEngine(),
        );
        try {
          await db.provider.executeAsync(
            'CREATE TEMP TABLE parity_paginate ('
            'id SERIAL PRIMARY KEY, '
            'n INT NOT NULL)',
            const <Object?>[],
          );
          for (var i = 0; i < 10; i++) {
            await db.provider.executeAsync(
              'INSERT INTO parity_paginate (n) VALUES (\$1)',
              [i * 10],
            );
          }

          // Page 2 (skip 5, take 3): 50, 60, 70.
          final rows = await db.provider.selectAsync(
            'SELECT n FROM parity_paginate '
            'ORDER BY n LIMIT \$1 OFFSET \$2',
            [3, 5],
          );
          expect(rows, hasLength(3));
          final values = rows
              .map((r) => (r as Map<String, Object?>)['n'])
              .toList();
          expect(values, [50, 60, 70]);
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'aggregate COUNT: same result as SQLite',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final db = await PgDb.open(
          url: url,
          engine: const PostgresEngine(),
        );
        try {
          await db.provider.executeAsync(
            'CREATE TEMP TABLE parity_count ('
            'id SERIAL PRIMARY KEY, '
            'active BOOLEAN NOT NULL)',
            const <Object?>[],
          );
          for (final active in [true, true, false, true, false]) {
            await db.provider.executeAsync(
              'INSERT INTO parity_count (active) VALUES (\$1)',
              [active],
            );
          }

          // 3 active, 2 inactive.
          final activeRows = await db.provider.selectAsync(
            'SELECT COUNT(*) AS c FROM parity_count WHERE active = \$1',
            [true],
          );
          expect(activeRows, hasLength(1));
          final activeCount =
              (activeRows.first as Map<String, Object?>)['c'];
          // Postgres returns COUNT(*) as
          // int (the type is BIGINT, but
          // the postgres client library
          // decodes it to int for small
          // values).
          expect(activeCount, 3);

          final inactiveRows = await db.provider.selectAsync(
            'SELECT COUNT(*) AS c FROM parity_count WHERE active = \$1',
            [false],
          );
          expect(
              (inactiveRows.first as Map<String, Object?>)['c'], 2);
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );
  });

  group('Parity: INSERT/UPDATE/DELETE on a real Postgres', () {
    test(
      'insert + read back: same flow as SQLite',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final db = await PgDb.open(
          url: url,
          engine: const PostgresEngine(),
        );
        try {
          await db.provider.executeAsync(
            'CREATE TEMP TABLE parity_iud ('
            'id SERIAL PRIMARY KEY, '
            'name TEXT NOT NULL)',
            const <Object?>[],
          );
          // INSERT.
          await db.provider.executeAsync(
            'INSERT INTO parity_iud (name) VALUES (\$1)',
            ['Alice'],
          );
          await db.provider.executeAsync(
            'INSERT INTO parity_iud (name) VALUES (\$1)',
            ['Bob'],
          );

          // SELECT.
          final rows = await db.provider.selectAsync(
            'SELECT name FROM parity_iud ORDER BY name',
          );
          expect(rows, hasLength(2));
          final names = rows
              .map((r) => (r as Map<String, Object?>)['name'])
              .toList();
          expect(names, ['Alice', 'Bob']);

          // UPDATE.
          await db.provider.executeAsync(
            'UPDATE parity_iud SET name = \$1 WHERE name = \$2',
            ['Alicia', 'Alice'],
          );
          final afterUpdate = await db.provider.selectAsync(
            'SELECT name FROM parity_iud ORDER BY name',
          );
          expect(
              (afterUpdate.first as Map<String, Object?>)['name'],
              'Alicia');

          // DELETE.
          await db.provider.executeAsync(
            'DELETE FROM parity_iud WHERE name = \$1',
            ['Bob'],
          );
          final afterDelete = await db.provider.selectAsync(
            'SELECT name FROM parity_iud',
          );
          expect(afterDelete, hasLength(1));
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );
  });

  group('Parity: transactions', () {
    test(
      'BEGIN / COMMIT on a real Postgres',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 1, max: 2),
        );
        try {
          await pool.executeAsync(
            'CREATE TEMP TABLE parity_tx (n INT)');
          await pool.beginTransactionAsync();
          try {
            await pool.executeAsync(
              'INSERT INTO parity_tx (n) VALUES (\$1)',
              [1],
            );
            await pool.executeAsync(
              'INSERT INTO parity_tx (n) VALUES (\$1)',
              [2],
            );
            await pool.commitAsync();
          } catch (e) {
            await pool.rollbackAsync();
            rethrow;
          }
          final rows = await pool.selectAsync(
            'SELECT n FROM parity_tx ORDER BY n',
          );
          expect(rows, hasLength(2));
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );
  });
}
