// Connection tests for d_rocket_engine_postgres.
//
// These tests verify that the engine can
// actually connect to a real Postgres instance
// and round-trip a SELECT 1. They are SKIPPED
// if the TEST_PG_URL env var is not set, so
// the suite can run in CI environments that
// don't have Postgres.

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  setUpPostgres();

  group('PostgresQueryProvider.open', () {
    test(
      'connects and runs a trivial query',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) {
          return; // pgSkipReason below handles the skip
        }
        final provider = await PostgresQueryProvider.openFromUrl(url: url);
        try {
          final rows = await provider.selectAsync('SELECT 1 AS one');
          expect(rows, hasLength(1));
          // The result column name is whatever Postgres
          // gives us for `AS one` — typically 'one'.
          final row = rows.first as Map<String, Object?>;
          expect(row.values.first, equals(1));
        } finally {
          await provider.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      '? placeholder is rewritten to \$N on the wire',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) {
          return;
        }
        final provider = await PostgresQueryProvider.openFromUrl(url: url);
        try {
          // The dev can use `?` placeholders
          // even though the Postgres wire
          // protocol uses $1, $2, ... — the
          // provider rewrites them.
          final rows = await provider.selectAsync(
            'SELECT 1 + ? AS result',
            [2],
          );
          expect(rows, hasLength(1));
          final row = rows.first as Map<String, Object?>;
          expect(row['result'], equals(3));
        } finally {
          await provider.disposeAsync();
        }
      },
      skip: pgSkipReason,
    );

    test(
      'isOpen reflects the underlying connection state',
      () async {
        final url = testPgUrlOrNull;
        if (url == null) {
          return;
        }
        final provider = await PostgresQueryProvider.openFromUrl(url: url);
        expect(provider.isOpen, isTrue);
        await provider.disposeAsync();
        expect(provider.isOpen, isFalse);
      },
      skip: pgSkipReason,
    );
  });
}
