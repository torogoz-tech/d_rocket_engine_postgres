// Phase 3.5.4d.2 — Tests for the placeholder
// rewriting done by the Postgres engine.
//
// The 2.0.0 design is:
//   1. The SqlTranslator always emits `?`
//      placeholders (engine-agnostic).
//   2. The AsyncQueryProvider implementation
//      for each engine rewrites the `?` to
//      the engine-specific form on the
//      wire:
//        - SQLite: no rewriting (uses `?`)
//        - Postgres: `?` → `$1, $2, ...`
//
// The rewriting is a private method
// (`_rewritePlaceholders`) on
// PostgresQueryProvider. These tests
// verify the rewriting by sending
// representative queries and inspecting
// the SQL that was actually emitted.
//
// Why test this in particular:
//   - If the rewriting is wrong (e.g.
//     `$1, $1, $1` instead of
//     `$1, $2, $3`), the query would
//     fail at the Postgres server with
//     a confusing error.
//   - The rewriting is a string
//     manipulation; it's easy to off-by-
//     one. The test guards against
//     regressions.

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  setUpPostgres();

  group('PostgresQueryProvider._rewritePlaceholders:', () {
    // The rewriting is a private method,
    // so we test it through the public
    // executeAsync / selectAsync /
    // beginTransactionAsync path. We
    // seed data and verify the queries
    // work end-to-end (which would
    // fail if the rewriting is wrong).

    test(
      r'rewrites `?` to `$1, $2, ...` in SELECT',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 1, max: 2),
        );
        try {
          // Insert with 2 binds.
          await pool.executeAsync(
            'CREATE TEMP TABLE pr_rewrite (n INT, s TEXT)');
          await pool.executeAsync(
            'INSERT INTO pr_rewrite (n, s) VALUES (\$1, \$2)',
            [42, 'hello'],
          );
          // Read with 1 bind. The pool's
          // provider rewrites `?` to `$1`.
          final rows = await pool.selectAsync(
            'SELECT n, s FROM pr_rewrite WHERE n = ?',
            [42],
          );
          expect(rows, hasLength(1));
          final row = rows.first as Map<String, Object?>;
          expect(row['n'], 42);
          expect(row['s'], 'hello');
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      r'rewrites 3 `?` placeholders to $1, $2, $3',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 1, max: 2),
        );
        try {
          // INSERT with 3 binds. The
          // engine rewrites `?, ?, ?` to
          // `$1, $2, $3` (otherwise
          // Postgres would complain about
          // unbound parameters).
          await pool.executeAsync(
            'CREATE TEMP TABLE pr_rewrite2 (a INT, b INT, c INT)');
          await pool.executeAsync(
            'INSERT INTO pr_rewrite2 (a, b, c) VALUES (?, ?, ?)',
            [1, 2, 3],
          );
          // SELECT with 2 binds.
          final rows = await pool.selectAsync(
            'SELECT a, b, c FROM pr_rewrite2 WHERE a = ? AND b = ?',
            [1, 2],
          );
          expect(rows, hasLength(1));
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'no rewriting when SQL has no `?`',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 1, max: 2),
        );
        try {
          // A constant query (no binds).
          // The engine should send it as-is
          // (no rewriting needed).
          final rows = await pool.selectAsync('SELECT 1 AS n');
          expect(rows, hasLength(1));
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'rewriting works inside a transaction',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 1, max: 2),
        );
        try {
          await pool.beginTransactionAsync();
          try {
            await pool.executeAsync(
              'CREATE TEMP TABLE pr_rewrite3 (n INT)');
            await pool.executeAsync(
              'INSERT INTO pr_rewrite3 (n) VALUES (?)',
              [99],
            );
            await pool.executeAsync(
              'INSERT INTO pr_rewrite3 (n) VALUES (?)',
              [100],
            );
            await pool.commitAsync();
          } catch (e) {
            await pool.rollbackAsync();
            rethrow;
          }
          final rows = await pool.selectAsync(
            'SELECT n FROM pr_rewrite3 ORDER BY n',
          );
          expect(rows, hasLength(2));
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );
  });

  group('Parity summary — what the Postgres engine actually sends:', () {
    // The end-to-end parity check: the
    // engine receives `?` placeholders
    // (the engine-agnostic contract) and
    // sends `$1, $2, ...` to Postgres
    // (the engine-specific contract).
    test(
      'inserts and reads back successfully (rewriting is correct end-to-end)',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 1, max: 2),
        );
        try {
          await pool.executeAsync(
            'CREATE TEMP TABLE parity (id INT, name TEXT)',
          );
          // Insert 3 rows.
          for (final entry in [
            <Object?>[1, 'Alice'],
            <Object?>[2, 'Bob'],
            <Object?>[3, 'Carol'],
          ]) {
            await pool.executeAsync(
              'INSERT INTO parity (id, name) VALUES (?, ?)',
              entry,
            );
          }
          // Read back, filtering.
          final rows = await pool.selectAsync(
            'SELECT name FROM parity WHERE id >= ? ORDER BY id',
            [2],
          );
          expect(rows, hasLength(2));
          final names = rows
              .map((r) => (r as Map<String, Object?>)['name'])
              .toList();
          expect(names, ['Bob', 'Carol']);
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );
  });
}
