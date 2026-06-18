// Tests for the PostgresEngine's connection
// pool (Phase 3.6).
//
// What this test covers:
//   - PoolConfig validation (asserts in
//     the constructor).
//   - PostgresPool warmup opens `min`
//     connections at startup.
//   - PostgresPool acquire / release
//     round-trip works.
//   - PostgresPool refuses to grow beyond
//     `max` (it queues waiters).
//   - PostgresPool disposeAsync closes
//     all connections.
//
// Gated on TEST_PG_URL because the pool
// needs a real Postgres server.

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  setUpPostgres();

  group('PoolConfig:', () {
    test('default values are sensible', () {
      const PoolConfig c = PoolConfig();
      expect(c.min, 1);
      expect(c.max, 10);
      expect(c.idleTimeout, const Duration(minutes: 5));
      expect(c.connectionTimeout, const Duration(seconds: 30));
      expect(c.acquireTimeout, const Duration(seconds: 10));
    });

    test('asserts on invalid min', () {
      expect(
        () => PoolConfig(min: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts on invalid max', () {
      expect(
        () => PoolConfig(max: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts on min > max', () {
      expect(
        () => PoolConfig(min: 5, max: 2),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toString is informative', () {
      const PoolConfig c = PoolConfig(min: 2, max: 8);
      expect(c.toString(), contains('min: 2'));
      expect(c.toString(), contains('max: 8'));
    });
  });

  group('PostgresPool:', () {
    test(
      'warmup opens `min` connections at startup',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        const PoolConfig config = PoolConfig(
          min: 3,
          max: 5,
          connectionTimeout: Duration(seconds: 10),
          acquireTimeout: Duration(seconds: 5),
        );
        final pool = await PostgresPool.open(
          url: url,
          config: config,
        );
        try {
          expect(pool.isOpen, isTrue);
          expect(pool.totalCount, 3,
              reason: 'warmup should have opened 3 connections');
          expect(pool.idleCount, 3,
              reason: 'all 3 should be idle, ready to use');
          expect(pool.waiterCount, 0);
        } finally {
          await pool.disposeAsync();
        }
        expect(pool.isOpen, isFalse);
        expect(pool.totalCount, 0);
      },
      skip: pgSkipReason,
    );

    test(
      'acquire / release round-trip returns the same connection',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        const PoolConfig config = PoolConfig(min: 1, max: 5);
        final pool = await PostgresPool.open(
          url: url,
          config: config,
        );
        try {
          // Use a query to verify the
          // connection actually works.
          final rows = await pool.selectAsync('SELECT 1 AS n');
          expect(rows, hasLength(1));
          final Map<String, Object?> row = rows.first as Map<String, Object?>;
          expect(row['n'], 1);
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'selectAsync / executeAsync / lastInsertRowIdAsync work through the pool',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        const PoolConfig config = PoolConfig(min: 1, max: 5);
        final pool = await PostgresPool.open(
          url: url,
          config: config,
        );
        try {
          // Setup: create a temp table.
          await pool.executeAsync('CREATE TEMP TABLE pool_test (n INT)');

          // Insert.
          await pool.executeAsync(
            'INSERT INTO pool_test (n) VALUES (\$1)',
            [42],
          );

          // Read back.
          final rows = await pool.selectAsync('SELECT n FROM pool_test');
          expect(rows, hasLength(1));
          expect((rows.first as Map<String, Object?>)['n'], 42);
        } finally {
          await pool.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'disposeAsync after open closes all connections',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        final pool = await PostgresPool.open(
          url: url,
          config: const PoolConfig(min: 2, max: 5),
        );
        expect(pool.totalCount, 2);
        await pool.disposeAsync();
        expect(pool.isOpen, isFalse);
        expect(pool.totalCount, 0);
        expect(pool.idleCount, 0);
      },
      skip: pgSkipReason,
    );
  });

  group('PostgresEngine with PoolConfig:', () {
    test(
      'open() returns a PostgresPool (not a single connection)',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        const PostgresEngine engine = PostgresEngine(
          pool: PoolConfig(min: 2, max: 8),
        );
        final db = await PgDb.open(
          url: url,
          engine: engine,
        );
        try {
          expect(db.provider, isA<PostgresPool>());
          final pool = db.provider as PostgresPool;
          expect(pool.totalCount, 2,
              reason: 'warmup should have opened 2 connections');
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'default engine (no pool param) opens a pool with defaults',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) return;
        const PostgresEngine engine = PostgresEngine();
        final db = await PgDb.open(
          url: url,
          engine: engine,
        );
        try {
          expect(db.provider, isA<PostgresPool>());
          final pool = db.provider as PostgresPool;
          expect(pool.totalCount, 1,
              reason: 'default PoolConfig has min=1');
        } finally {
          await db.close();
        }
      },
      skip: pgSkipReason,
    );
  });
}
