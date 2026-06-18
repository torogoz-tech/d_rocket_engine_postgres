/// The `DbSet<T>.asQueryable` extension for
/// the Postgres engine.
///
/// In d_rocket 2.0.0, the Postgres engine
/// uses the engine-agnostic [Queryable] from
/// d_rocket core (the same class the SQLite
/// engine uses). The only engine-specific
/// bits are:
///
/// 1. The [PostgresDialect] (overrides
///    `STRPOS` for String.contains and
///    `jsonb_build_object` for map literals).
/// 2. The [PostgresQueryProvider] (the
///    wire-protocol client; rewrites `?`
///    placeholders to `$1, $2, ...` on the
///    wire).
///
/// The Postgres engine is async-only (it
/// does NOT implement [LegacySyncQueryProvider]
/// like the SQLite engine does). Calling
/// the legacy sync LINQ methods
/// (`toList_`, `count_`, `first_`, …)
/// throws a clear "this engine is async-only;
/// use the *Async_ variant" error.
///
/// The result is that the Postgres engine
/// gets the FULL LINQ surface for free:
/// every operator that the SQLite engine
/// has (where_, select_, orderBy_, take_,
/// skip_, groupBy_, join_, selectMany_,
/// union_, intersect_, except_, distinct_,
/// thenBy_, firstOrDefault_, etc.) is
/// available in the Postgres engine with
/// zero additional code — the engine only
/// contributed the [PostgresDialect] and the
/// [PostgresQueryProvider].
library;

import 'package:d_rocket/d_rocket.dart';

import 'pg/pg_dialect.dart';
import 'pg/query_provider.dart';

/// helper: extracts a [PostgresQueryProvider]
/// from a `DbSet<T>` (via the async
/// attachment slot). Returns null if no
/// Postgres provider is attached.
PostgresQueryProvider? _pgProviderOf<T>(DbSet<T> set) {
  final AsyncQueryProvider? fromAsync = set.asyncProvider;
  if (fromAsync is PostgresQueryProvider) return fromAsync;
  return null;
}

/// (the bridge): a `DbSet<T>.asQueryable`
/// extension. Returns the engine-agnostic
/// [Queryable] from d_rocket core, wired
/// to the attached [PostgresQueryProvider]
/// and the [PostgresDialect].
extension PostgresDbSetExtension<T> on DbSet<T> {
  Queryable<T> asQueryable() {
    final PostgresQueryProvider? pg = _pgProviderOf(this);
    if (pg == null) {
      throw UnsupportedError(
        'DbSet<T>.asQueryable() requires a '
        'PostgresQueryProvider. Use `PgDb.set<T>()` '
        'instead of creating a DbSet directly — the '
        '`PgDb` facade auto-attaches the provider.',
      );
    }
    final EntityMeta meta = this.meta;
    if (meta.fromRow == null) {
      throw UnsupportedError(
        'DbSet<T>.asQueryable() requires the codegen-'
        'supplied `EntityMeta.fromRow`. Run the '
        '`d_rocket_builder:table` codegen.',
      );
    }
    // The engine-agnostic Queryable<T> from
    // d_rocket core, with:
    //   - asyncProvider: the Postgres engine
    //     (so toListAsync_ / countAsync_ /
    //     firstAsync_ work).
    //   - dialect: the PostgresDialect (so
    //     String.contains emits STRPOS, map
    //     literals emit jsonb_build_object).
    //   - provider: null (the Postgres engine
    //     is async-only; the legacy sync
    //     methods throw with a clear error).
    return Queryable<T>(
      asyncProvider: pg,
      dialect: const PostgresDialect(),
      table: meta.tableName,
      meta: meta,
      reader: (Map<String, Object?> row) => meta.fromRow!(row) as T,
      changeTracker: changeTracker,
    );
  }
}

/// (the LINQ surface): the LINQ operators
/// exposed directly on `DbSet<T>`. Each
/// one returns the engine-agnostic
/// [Queryable] from d_rocket core (or a
/// typed variant for `select<T2>`), so the
/// user chains them naturally:
///
/// ```dart
/// final adults = await db.set`<Person>`
/// .where(Expr.lambda([Expr.param('p')], p.age >= 18))
/// .orderBy(Expr.lambda([Expr.param('p')], p.name))
/// .take(10)
/// .toListAsync_();
/// ```
extension DbSetLinqExtension<T> on DbSet<T> {
  /// `WHERE` clause. Mirrors [Queryable.where_].
  Queryable<T> where(Expr predicate) => asQueryable().where_(predicate);

  /// `ORDER BY ... ASC`. Mirrors
  /// [Queryable.orderBy_].
  Queryable<T> orderBy(Expr keySelector) =>
      asQueryable().orderBy_(keySelector);

  /// `ORDER BY ... DESC`. Mirrors
  /// [Queryable.orderByDescending_].
  Queryable<T> orderByDescending(Expr keySelector) =>
      asQueryable().orderByDescending_(keySelector);

  /// `SELECT` projection. Mirrors
  /// [Queryable.select_]. The result
  /// type `T2` is inferred from the
  /// selector.
  Queryable<T2> select<T2>(Expr selector) =>
      asQueryable().select_<T2>(selector);

  /// `LIMIT n`. Mirrors [Queryable.take_].
  Queryable<T> take(int n) => asQueryable().take_(n);

  /// `OFFSET n`. Mirrors [Queryable.skip_].
  Queryable<T> skip(int n) => asQueryable().skip_(n);
}
