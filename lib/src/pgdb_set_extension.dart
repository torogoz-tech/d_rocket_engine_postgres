/// The `DbSet<T>.asQueryable` extension for
/// the Postgres engine.
///
/// Mirrors the SQLite engine's
/// `SqliteDbSetExtension<T>`: returns a
/// [PostgresQueryable] wired to the attached
/// [PostgresQueryProvider] + the
/// [PostgresDialect].
///
/// Most users don't need this directly —
/// the [DbSetLinqExtension] below exposes
/// the LINQ surface on `DbSet<T>` itself.
/// `asQueryable` is kept for advanced
/// cases.
///
/// Throws [UnsupportedError] when no
/// [PostgresQueryProvider] is attached
/// (i.e. when a `DbSet` is created
/// outside of a `PgDb`).
library;

import 'package:d_rocket/d_rocket.dart';

import 'pg/pg_dialect.dart';
import 'pg/query_provider.dart';
import 'pg/queryable.dart';

/// helper: extracts a [PostgresQueryProvider]
/// from a `DbSet<T>` (via either the sync
/// or the async attachment slot). Returns
/// null if no Postgres provider is attached.
PostgresQueryProvider? _pgProviderOf<T>(DbSet<T> set) {
  final Object? fromAttach = set.get<PostgresQueryProvider>();
  if (fromAttach is PostgresQueryProvider) return fromAttach;
  final AsyncQueryProvider? fromAsync = set.asyncProvider;
  if (fromAsync is PostgresQueryProvider) return fromAsync;
  return null;
}

/// (the bridge): a `DbSet<T>.asQueryable`
/// extension. Returns a [PostgresQueryable]
/// wired to the attached [PostgresQueryProvider].
extension PostgresDbSetExtension<T> on DbSet<T> {
  PostgresQueryable<T> asQueryable() {
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
    return PostgresQueryable<T>(
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
/// one returns a [PostgresQueryable] (or a
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
  /// `WHERE` clause. Mirrors
  /// [PostgresQueryable.where_].
  PostgresQueryable<T> where(Expr predicate) => asQueryable().where_(predicate);

  /// `ORDER BY ... ASC`. Mirrors
  /// [PostgresQueryable.orderBy_].
  PostgresQueryable<T> orderBy(Expr keySelector) =>
      asQueryable().orderBy_(keySelector);

  /// `ORDER BY ... DESC`. Mirrors
  /// [PostgresQueryable.orderByDescending_].
  PostgresQueryable<T> orderByDescending(Expr keySelector) =>
      asQueryable().orderByDescending_(keySelector);

  /// `SELECT` projection. Mirrors
  /// [PostgresQueryable.select_]. The
  /// result type `T2` is inferred from
  /// the selector.
  PostgresQueryable<T2> select<T2>(Expr selector) =>
      asQueryable().select_<T2>(selector);

  /// `LIMIT n`. Mirrors
  /// [PostgresQueryable.take_].
  PostgresQueryable<T> take(int n) => asQueryable().take_(n);

  /// `OFFSET n`. Mirrors
  /// [PostgresQueryable.skip_].
  PostgresQueryable<T> skip(int n) => asQueryable().skip_(n);
}
