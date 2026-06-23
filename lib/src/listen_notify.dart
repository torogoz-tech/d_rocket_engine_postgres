/// 2.0.0 — Postgres LISTEN/NOTIFY-based
/// reactive streams.
///
/// ## The problem
///
/// `DbSet<T>.watch()` polls the DB every N
/// seconds by default (1s in 2.0). For
/// latency-sensitive UIs (live dashboards,
/// chat, collaborative editors) that's
/// too slow. Postgres has a native
/// push-based primitive: `LISTEN <channel>`
/// + `NOTIFY <channel, payload>`.
///
/// ## How it works
///
/// 1. **Schema setup**: install a row-level
///    trigger on each table that fires
///    `pg_notify('d_rocket_changes_<table>', op)`
///    on INSERT/UPDATE/DELETE. See
///    [installNotifyTriggersSql] for the
///    DDL.
///
/// 2. **Open a listener**: allocate a
///    dedicated connection from the pool
///    (not shared with regular queries) and
///    `LISTEN d_rocket_changes_<table>` on
///    it. Postgres delivers notifications
///    asynchronously, so this connection
///    sits idle.
///
/// 3. **Translate**: each
///    `Notification.payload` is a JSON
///    `{op: 'INSERT'|'UPDATE'|'DELETE',
///    pkey: ...}` emitted by
///    the trigger. We translate to
///    [ChangeEvent] (same type used by the
///    SQLite [ChangeTracker]) so consumers
///    can wire either engine into
///    `DbSet.watch()`.
///
/// ## Threading
///
/// LISTEN consumes no CPU while idle. The
/// listener connection must not be used
/// for regular queries (mixing LISTEN and
/// traffic on the same connection breaks
/// delivery guarantees — Postgres warns
/// explicitly). We allocate it from the
/// pool via [PostgresPool.acquireListener].
///
/// ## Reconnection
///
/// If the listener connection dies, the
/// stream emits a done-event and the user
/// can re-open + re-LISTEN. A 2.1 feature
/// will add automatic reconnection with
/// exponential backoff. For the watch()
/// use case (UI re-renders on each emit),
/// a brief gap is acceptable.
///
/// ## Limitations (2.0.0)
///
/// * Single pool per listener. Cross-pool
///   notification routing is a 2.1 feature.
/// * Payload size limited to 8 KB (Postgres
///   NOTIFY limit). For tables with very
///   wide rows, the trigger emits just
///   `{op, pkey}` and consumers must
///   re-fetch.
library;

import 'dart:async';
import 'dart:convert';

import 'package:d_rocket/d_rocket.dart';
import 'package:postgres/postgres.dart';

import 'pg/pool.dart';
import 'pg/query_provider.dart';

/// The kind of a [DbChangeEvent].
enum DbChangeOp {
  insert,
  update,
  delete;

  static DbChangeOp? fromString(String op) {
    switch (op.toUpperCase()) {
      case 'INSERT':
        return DbChangeOp.insert;
      case 'UPDATE':
        return DbChangeOp.update;
      case 'DELETE':
        return DbChangeOp.delete;
      default:
        return null;
    }
  }
}

/// A change event produced by the Postgres
/// LISTEN/NOTIFY pipeline. Wire-compatible
/// with the engine-agnostic
/// `ChangeTracker` `Stream<ChangeEvent>`:
/// the same `type` enum values, with
/// Postgres-specific extras on
/// [op] and [primaryKey].
class DbChangeEvent {
  const DbChangeEvent({
    required this.type,
    required this.op,
    this.primaryKey,
    this.row,
    this.entity,
    this.trackedEntry,
  });

  /// The engine-agnostic change kind
  /// (used by `ChangeTracker`). Mapped from
  /// [op]:
  /// * INSERT → [ChangeEventType.added]
  /// * UPDATE → [ChangeEventType.modified]
  /// * DELETE → [ChangeEventType.removed]
  final ChangeEventType type;

  /// The Postgres-specific operation kind.
  /// Useful for callers that want to
  /// distinguish "row was deleted" from
  /// "row was updated to deleted-flag=true".
  final DbChangeOp op;

  /// The primary key of the changed row
  /// (parsed from the JSON payload). Null
  /// when the trigger couldn't fit it in
  /// the payload (very-wide rows).
  final Object? primaryKey;

  /// The full NEW (or OLD) row, as a
  /// `Map<String, Object?>` from the JSON
  /// payload. Null when the trigger
  /// dropped it to fit in the 8 KB NOTIFY
  /// limit (very-wide rows) OR for DELETE
  /// events (only the OLD.id is emitted).
  final Map<String, Object?>? row;

  /// The d_rocket entity (when wired into
  /// a `ChangeTracker`). Null when this
  /// event comes straight from the NOTIFY
  /// stream without tracker integration.
  final Object? entity;

  /// The d_rocket tracked entry (when
  /// wired into a `ChangeTracker`). Null
  /// for raw NOTIFY events.
  final TrackedEntry? trackedEntry;
}

/// A reactive change stream for the
/// Postgres engine. The user opens one of
/// these per table they want to watch:
///
/// ```dart
/// final listener = await PostgresListenNotify.open(
///   pool: myPool,
///   table: 'users',
/// );
/// final changes = listener.stream; // Stream<DbChangeEvent>
/// ```
///
/// The stream emits a [DbChangeEvent] for
/// every INSERT/UPDATE/DELETE on the
/// watched table. The user is expected to
/// pipe this into `DbSet<T>.watch()` (or
/// just consume directly).
class PostgresListenNotify {
  /// The dedicated listener connection.
  /// Acquired from the pool (not shared
  /// with regular queries).
  final PostgresQueryProvider _conn;

  /// The underlying `Connection.channels`
  /// stream, filtered to our channel.
  /// Note: `Channels[]` returns
  /// `Stream<String>` (just the payload),
  /// not `Stream<Notification>`. We wrap
  /// the payloads into a synthetic
  /// [Notification] for the public API.
  final Stream<String> _channelStream;

  /// The user-facing stream of
  /// [DbChangeEvent]s. Derived from
  /// [_channelStream] + payload parsing.
  late final Stream<DbChangeEvent> stream;

  /// The table name (used to build the
  /// channel: `d_rocket_changes_<table>`).
  final String table;

  /// The channel name we LISTEN on.
  static String channelForTable(String table) =>
      'd_rocket_changes_$table';

  PostgresListenNotify._(
    this._conn,
    this._channelStream,
    this.table,
  ) {
    stream = _channelStream
        .map((String payload) =>
            _payloadToChangeEvent(payload))
        .where((DbChangeEvent? e) => e != null)
        .cast<DbChangeEvent>();
  }

  /// Opens a listener for [table] using a
  /// dedicated connection acquired from
  /// [pool].
  ///
  /// The caller MUST first run
  /// [installNotifyTriggersSql] for [table]
  /// as part of their migration, or the
  /// stream will never emit (no trigger
  /// fires).
  static Future<PostgresListenNotify> open({
    required PostgresPool pool,
    required String table,
  }) async {
    final PostgresQueryProvider conn = await pool.acquireListener();
    final String channel = channelForTable(table);
    await conn.connection.execute('LISTEN "$channel"');
    // `Channels[channel]` returns a fresh
    // filtered stream of payloads (as
    // `Stream<String>`) each time. We grab
    // one and cache it; subsequent listens
    // are idempotent on the same channel.
    final Stream<String> filtered =
        conn.connection.channels[channel];
    return PostgresListenNotify._(conn, filtered, table);
  }

  /// Closes the listener and releases the
  /// dedicated connection back to the pool.
  Future<void> close() async {
    try {
      final String channel = channelForTable(table);
      // Best-effort UNLISTEN. If the
      // connection is already dead, ignore.
      await _conn.connection.execute('UNLISTEN "$channel"');
    } on Object {
      // ignored — see "Reconnection" in the
      // file-level doc.
    } finally {
      await _conn.disposeAsync();
    }
  }

  /// Translates a Postgres notification
  /// payload (the raw JSON string delivered
  /// by `LISTEN/NOTIFY`) to a
  /// [DbChangeEvent] (or null if the
  /// payload was malformed).
  static DbChangeEvent? _payloadToChangeEvent(String payload) {
    try {
      final Map<String, Object?> json =
          jsonDecode(payload) as Map<String, Object?>;
      final String? opStr = json['op'] as String?;
      if (opStr == null) return null;
      final DbChangeOp? op = DbChangeOp.fromString(opStr);
      if (op == null) return null;

      // The trigger serializes the row
      // as a JSON string (avoids nested
      // escaping issues in the
      // pg_notify payload). Parse it.
      final Object? rowRaw = json['row'];
      Map<String, Object?>? row;
      if (rowRaw is String) {
        try {
          row = jsonDecode(rowRaw) as Map<String, Object?>;
        } on Object {
          row = null;
        }
      }

      // The PK may be a string-encoded
      // JSON value (single-quoted number,
      // etc.). Parse it.
      final Object? pkeyRaw = json['pkey'];
      Object? pkey;
      if (pkeyRaw is String) {
        try {
          pkey = jsonDecode(pkeyRaw);
        } on Object {
          pkey = pkeyRaw;
        }
      } else {
        pkey = pkeyRaw;
      }

      return DbChangeEvent(
        type: _changeEventType(op),
        op: op,
        primaryKey: pkey,
        row: row,
      );
    } on Object {
      return null;
    }
  }

  static ChangeEventType _changeEventType(DbChangeOp op) {
    switch (op) {
      case DbChangeOp.insert:
        return ChangeEventType.added;
      case DbChangeOp.update:
        return ChangeEventType.modified;
      case DbChangeOp.delete:
        return ChangeEventType.removed;
    }
  }
}

/// The DDL for the Postgres trigger that
/// fires NOTIFY on row INSERT/UPDATE/
/// DELETE for [tableName].
///
/// The user runs this as part of their
/// migration (or copies it into a manual
/// migration file).
///
/// ## Payload format
///
/// ```json
/// {
///   "op": "INSERT" | "UPDATE" | "DELETE",
///   "row": "<JSON-serialized NEW or OLD row>",
///   "pkey": "<JSON-serialized NEW.id or OLD.id>"
/// }
/// ```
///
/// ## Wide rows
///
/// For wide rows (the serialized row
/// exceeds 7 KB; the NOTIFY payload
/// limit is 8 KB), the trigger emits
/// just `{op, pkey}` and drops the row.
/// Consumers detect this (no `row` key in
/// the JSON) and re-fetch if they need
/// the full row.
String installNotifyTriggersSql(String tableName) {
  // The two trigger functions (one for
  // INSERT/UPDATE, one for DELETE) are
  // required because NEW is null in DELETE
  // triggers and OLD is null in INSERT.
  //
  // Both call `pg_notify(...)` which is
  // non-transactional — the notification
  // fires at COMMIT time, not row time.
  // This is exactly what we want: a
  // watcher sees the post-commit state.
  return '''
CREATE OR REPLACE FUNCTION d_rocket_notify_${tableName}_upsert()
RETURNS TRIGGER AS \$\$
DECLARE
  payload TEXT;
  row_json TEXT;
  pkey_json TEXT;
BEGIN
  pkey_json := json_build_object('id', NEW.id)::TEXT;
  row_json := to_jsonb(NEW)::TEXT;
  IF length(row_json) < 7000 THEN
    payload := json_build_object(
      'op', TG_OP,
      'row', row_json,
      'pkey', pkey_json
    )::TEXT;
  ELSE
    payload := json_build_object(
      'op', TG_OP,
      'pkey', pkey_json
    )::TEXT;
  END IF;
  PERFORM pg_notify('d_rocket_changes_$tableName', payload);
  RETURN NEW;
END;
\$\$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION d_rocket_notify_${tableName}_delete()
RETURNS TRIGGER AS \$\$
DECLARE
  payload TEXT;
  pkey_json TEXT;
BEGIN
  pkey_json := json_build_object('id', OLD.id)::TEXT;
  payload := json_build_object(
    'op', TG_OP,
    'pkey', pkey_json
  )::TEXT;
  PERFORM pg_notify('d_rocket_changes_$tableName', payload);
  RETURN OLD;
END;
\$\$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS d_rocket_notify_${tableName}_ins ON $tableName;
DROP TRIGGER IF EXISTS d_rocket_notify_${tableName}_upd ON $tableName;
DROP TRIGGER IF EXISTS d_rocket_notify_${tableName}_del ON $tableName;

CREATE TRIGGER d_rocket_notify_${tableName}_ins
  AFTER INSERT ON $tableName
  FOR EACH ROW EXECUTE FUNCTION
    d_rocket_notify_${tableName}_upsert();

CREATE TRIGGER d_rocket_notify_${tableName}_upd
  AFTER UPDATE ON $tableName
  FOR EACH ROW EXECUTE FUNCTION
    d_rocket_notify_${tableName}_upsert();

CREATE TRIGGER d_rocket_notify_${tableName}_del
  AFTER DELETE ON $tableName
  FOR EACH ROW EXECUTE FUNCTION
    d_rocket_notify_${tableName}_delete();
''';
}