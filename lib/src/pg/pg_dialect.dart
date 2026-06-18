/// The Postgres-flavoured [SqlDialect].
///
/// Implements the three dialect-specific
/// bits that the [SqlTranslator] in
/// d_rocket core needs to emit valid
/// Postgres SQL:
///
/// * [stringContainsFunction]: Postgres
///   uses `STRPOS(col, ?) > 0` instead of
///   SQLite's `INSTR(col, ?) > 0`.
///   `STRPOS` is the SQL-standard name.
///   (`POSITION(? IN col) > 0` is equivalent
///   but `STRPOS` is shorter and is what
///   most ORMs emit.)
/// * [jsonObjectFunction]: Postgres uses
///   `jsonb_build_object(...)` instead of
///   SQLite's `json_object(...)`. `jsonb`
///   is the binary form (faster to query,
///   smaller on disk); the alternative
///   `json_build_object` produces a `json`
///   value which is text-based.
/// * [placeholder]: `?` (the translator
///   always emits `?`; the
///   [PostgresQueryProvider] rewrites `?`
///   to `$1, $2, ...` on the wire so this
///   method's return value is informational
///   only — the d_rocket 2.0.0 implementation
///   does NOT use the dialect's placeholder
///   to rewrite the SQL; the provider does
///   it).
library;

import 'package:d_rocket/d_rocket.dart';

/// The Postgres dialect. Engine-specific
/// override of [SqlDialect] for the
/// Postgres wire-protocol client.
class PostgresDialect extends SqlDialect {
  const PostgresDialect();

  @override
  String stringContainsFunction() => 'STRPOS';

  @override
  String jsonObjectFunction() => 'jsonb_build_object';
}
