/// The Postgres-flavoured [Queryable].
///
/// d_rocket 2.0.0's LINQ surface for the
/// Postgres engine. Mirrors the SQLite
/// engine's `Queryable<T>` for the most-
/// used operators (where, select, orderBy,
/// take, skip, toListAsync_, countAsync_,
/// firstAsync_).
///
/// ## Engine-agnostic core, engine-specific bits
///
/// This class is a thin layer over the
/// `SqlTranslator` (in d_rocket core) and
/// the `AsyncQueryProvider` (the Postgres
/// engine's `PostgresQueryProvider`).
/// The translator walks the LINQ state
/// (where, select, orderBy, …) and emits
/// the SQL. The provider executes the
/// SQL against the Postgres connection
/// (and rewrites `?` placeholders to
/// `$1, $2, ...` on the wire).
///
/// The only Postgres-specific piece is
/// the [PostgresDialect] (in
/// `pg_dialect.dart`), which the translator
/// uses to emit `STRPOS` for
/// `String.contains` and `jsonb_build_object`
/// for map literals.
///
/// ## Scope (2.0.0 MVP)
///
/// This class covers the 80% LINQ case:
/// the 5 operators + 3 terminals listed
/// above. Joins (`join_`, `groupJoin_`),
/// grouping (`groupBy_`), set operations
/// (`union_`, `intersect_`, `except_`),
/// and `selectMany_` are 2.1 features. For
/// 2.0.0, use the raw
/// `db.provider.selectAsync(...)` for
/// those cases.
library;

import 'dart:async';

import 'package:d_rocket/d_rocket.dart';

import 'pg_dialect.dart';
import 'query_provider.dart';

/// A function that maps a `Row` to a user
/// value of type [T]. Mirrors the
/// `ResultRowReader` typedef in
/// d_rocket_engine_sqlite.
typedef PgResultRowReader<T> = T Function(Map<String, Object?> row);

/// The Postgres engine's [Queryable].
///
/// See the library doc for the scope and
/// architecture.
class PostgresQueryable<T> extends IQueryable<T> {
  /// The async engine-agnostic provider.
  /// For Postgres, this is the
  /// [PostgresQueryProvider].
  final AsyncQueryProvider asyncProvider;

  /// The SQL dialect. Always [PostgresDialect]
  /// for this class.
  final SqlDialect dialect;

  /// The table name.
  final String table;

  /// The entity metadata (column list, PK,
  /// etc.). Used to emit `SELECT col1, col2,
  /// ...` instead of `SELECT *`.
  final EntityMeta meta;

  /// Maps a row to a value of type [T].
  final PgResultRowReader<T> reader;

  /// The change tracker (optional). When
  /// set, the `watch()` API re-emits the
  /// queryable when the tracker reports a
  /// change. For 2.0.0 the watch uses
  /// simple polling; a future 2.1 release
  /// uses LISTEN/NOTIFY for native
  /// push-based invalidation.
  final ChangeTracker? changeTracker;

  /// The `WHERE` predicate (null = no filter).
  Expr? _where;

  /// The `SELECT` projection (null = select
  /// all columns). When set, the terminal
  /// returns a different type `T2` (this
  /// is the `_SelectQueryable<T, T2>`
  /// pattern in the SQLite engine; for 2.0.0
  /// the Postgres engine uses a simpler
  /// `IQueryable<T2>` for the projection).
  final Expr? _select;

  /// The `ORDER BY` clauses (multiple
  /// `orderBy_` calls stack).
  final List<OrderByClause> _orderBy;

  /// `LIMIT n`.
  int? _take;

  /// `OFFSET n`.
  int? _skip;

  PostgresQueryable({
    required this.asyncProvider,
    required this.dialect,
    required this.table,
    required this.meta,
    required this.reader,
    this.changeTracker,
    Expr? where,
    Expr? select,
    List<OrderByClause> orderBy = const <OrderByClause>[],
    int? take,
    int? skip,
  })  : _where = where,
        _select = select,
        _orderBy = List<OrderByClause>.unmodifiable(orderBy),
        _take = take,
        _skip = skip;

  /// The IQueryable's [provider] getter
  /// (returns the in-memory LINQ provider,
  /// since [PostgresQueryable] only emits
  /// SQL when the `*Async_` terminal is
  /// called; the in-memory provider is
  /// never used).
  @override
  IQueryProvider get provider => EnumerableQueryProvider.instance;

  /// The expression that produced this
  /// queryable. For 2.0.0 we return the
  /// raw table expression (a `ConstExpr`
  /// with the table name) — the expression
  /// is informational; the actual SQL is
  /// built in [_buildSelect].
  @override
  Expr? get expression =>
      _where != null || _select != null || _orderBy.isNotEmpty
          ? Expr.const_(table)
          : null;

  /// The IQueryable's [iterator] getter
  /// (from [Iterable]). The Postgres engine
  /// is async-only; calling `iterator` (the
  /// sync [Iterable] API) throws a clear
  /// error pointing to the async terminal.
  @override
  Iterator<T> get iterator {
    throw UnsupportedError(
      'PostgresQueryable<T> is async-only. Use toListAsync_() '
      '(and await it) instead of iterating the queryable. '
      'The Postgres wire-protocol client is async-only; the '
      'sync Iterable API is not available.',
    );
  }

  // ─── Operators ─────────────────────────────────────────────────

  /// `WHERE` clause. Returns a new
  /// queryable with the predicate added.
  /// Multiple `where_` calls combine with
  /// `AND`.
  PostgresQueryable<T> where_(Expr predicate) {
    final PostgresQueryable<T> copy = _copy();
    copy._where = _where == null
        ? predicate
        : Expr.binary('&&', _where!, predicate);
    return copy;
  }

  /// `SELECT` projection. Returns a new
  /// queryable with the projection added.
  PostgresQueryable<T2> select_<T2>(Expr selector) {
    return PostgresQueryable<T2>(
      asyncProvider: asyncProvider,
      dialect: dialect,
      table: table,
      meta: meta,
      reader: (Map<String, Object?> row) {
        throw UnimplementedError(
          'PostgresQueryable<T2>.reader: the projection selector '
          'must be evaluated in the WHERE/HAVING context. Use '
          'toListAsync_ and apply the selector to the result.',
        );
      },
      changeTracker: changeTracker,
      where: _where,
      select: selector,
      orderBy: _orderBy,
      take: _take,
      skip: _skip,
    );
  }

  /// `ORDER BY ... ASC`. Returns a new
  /// queryable with the ordering added.
  PostgresQueryable<T> orderBy_(Expr keySelector) {
    final PostgresQueryable<T> copy = _copy();
    copy._orderBy.add(OrderByClause(keySelector, descending: false));
    return copy;
  }

  /// `ORDER BY ... DESC`. Returns a new
  /// queryable with the descending
  /// ordering added.
  PostgresQueryable<T> orderByDescending_(Expr keySelector) {
    final PostgresQueryable<T> copy = _copy();
    copy._orderBy.add(OrderByClause(keySelector, descending: true));
    return copy;
  }

  /// `LIMIT n`. Returns a new queryable
  /// with the take added.
  PostgresQueryable<T> take_(int n) {
    final PostgresQueryable<T> copy = _copy();
    copy._take = n;
    return copy;
  }

  /// `OFFSET n`. Returns a new queryable
  /// with the skip added.
  PostgresQueryable<T> skip_(int n) {
    final PostgresQueryable<T> copy = _copy();
    copy._skip = n;
    return copy;
  }

  /// helper: clone this queryable.
  PostgresQueryable<T> _copy() {
    return PostgresQueryable<T>(
      asyncProvider: asyncProvider,
      dialect: dialect,
      table: table,
      meta: meta,
      reader: reader,
      changeTracker: changeTracker,
      where: _where,
      select: _select,
      orderBy: List<OrderByClause>.unmodifiable(_orderBy),
      take: _take,
      skip: _skip,
    );
  }

  // ─── SQL emission ─────────────────────────────────────────────

  /// Builds the full `SELECT ... WHERE ...
  /// ORDER BY ... LIMIT n OFFSET n` SQL
  /// and the bind list. The result is the
  /// `SqlFragment` the
  /// [AsyncQueryProvider.selectAsync] will
  /// run.
  SqlFragment _buildSelect() {
    final StringBuffer buf = StringBuffer();
    final List<Object?> binds = <Object?>[];

    const String tableAlias = 'u';
    final SqlTranslator tx =
        SqlTranslator(tableAlias: tableAlias, dialect: dialect);

    // SELECT clause.
    buf.write('SELECT ');
    if (_select != null) {
      final SqlFragment sel = _select.accept(tx);
      buf.write(sel.sql);
      binds.addAll(sel.binds);
    } else {
      // All columns: SELECT * FROM table u
      // (Postgres accepts SELECT *).
      buf.write('*');
    }

    // FROM clause.
    buf.write(' FROM $table u');

    // WHERE clause.
    if (_where != null) {
      final SqlFragment whereFrag = tx.translateLambda(_where!);
      buf.write(' WHERE ${whereFrag.sql}');
      binds.addAll(whereFrag.binds);
    }

    // ORDER BY clause.
    for (final OrderByClause clause in _orderBy) {
      final SqlFragment orderFrag = tx.translateLambda(clause.selector);
      buf.write(
        ' ORDER BY ${orderFrag.sql}${clause.descending ? ' DESC' : ' ASC'}',
      );
      binds.addAll(orderFrag.binds);
    }

    // LIMIT / OFFSET (Postgres syntax:
    // LIMIT n OFFSET m, no need for the
    // SQLite-style `LIMIT n, m`).
    if (_take != null) {
      buf.write(' LIMIT ?');
      binds.add(_take);
    }
    if (_skip != null) {
      buf.write(' OFFSET ?');
      binds.add(_skip);
    }

    return SqlFragment(buf.toString(), binds);
  }

  // ─── Terminals (async) ────────────────────────────────────────

  /// Executes the query and returns the
  /// mapped rows. This is the canonical
  /// terminal.
  Future<List<T>> toListAsync_() async {
    final SqlFragment frag = _buildSelect();
    final List<Object?> rows =
        await asyncProvider.selectAsync(frag.sql, frag.binds);
    return rows
        .cast<Map<String, Object?>>()
        .map(reader)
        .toList(growable: false);
  }

  /// Returns the number of rows that match
  /// the current state. Translates to
  /// `SELECT COUNT(*) FROM ...`.
  Future<int> countAsync_() async {
    final StringBuffer buf = StringBuffer();
    final List<Object?> binds = <Object?>[];
    final SqlTranslator tx = SqlTranslator(tableAlias: 'u', dialect: dialect);
    buf.write('SELECT COUNT(*) AS n FROM $table u');
    if (_where != null) {
      final SqlFragment whereFrag = tx.translateLambda(_where!);
      buf.write(' WHERE ${whereFrag.sql}');
      binds.addAll(whereFrag.binds);
    }
    final List<Object?> rows =
        await asyncProvider.selectAsync(buf.toString(), binds);
    final Map<String, Object?> first =
        rows.cast<Map<String, Object?>>().first;
    return first['n'] as int;
  }

  /// Returns the first row that matches
  /// the current state (or null if no
  /// rows match). Translates to
  /// `SELECT ... ORDER BY ... LIMIT 1`.
  Future<T?> firstAsync_() async {
    final SqlFragment frag = _buildSelect();
    // Add LIMIT 1 if not already there.
    final String sql = _take == null
        ? '${frag.sql} LIMIT 1'
        : frag.sql;
    final List<Object?> rows =
        await asyncProvider.selectAsync(sql, frag.binds);
    if (rows.isEmpty) return null;
    return reader(rows.cast<Map<String, Object?>>().first);
  }
}

/// A single `ORDER BY` clause.
class OrderByClause {
  final Expr selector;
  final bool descending;
  const OrderByClause(this.selector, {required this.descending});
}
