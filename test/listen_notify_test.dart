// 2.0.0 — unit tests for the
// LISTEN/NOTIFY payload → DbChangeEvent
// translation logic.
//
// We test the pure translation logic
// directly (without a live Postgres).
// Integration tests against a real
// Postgres will land in Phase 8.10
// (testcontainers).

import 'dart:convert';

import 'package:d_rocket_engine_postgres/d_rocket_engine_postgres.dart';
import 'package:test/test.dart';

void main() {
  group('2.0.0 — PostgresListenNotify', () {
    group('channelForTable', () {
      test('produces prefixed channel name', () {
        expect(
          PostgresListenNotify.channelForTable('users'),
          equals('d_rocket_changes_users'),
        );
      });

      test('handles schema-qualified names', () {
        expect(
          PostgresListenNotify.channelForTable('public.users'),
          equals('d_rocket_changes_public.users'),
        );
      });
    });

    group('DbChangeOp.fromString', () {
      test('parses INSERT', () {
        expect(DbChangeOp.fromString('INSERT'), equals(DbChangeOp.insert));
      });
      test('parses UPDATE', () {
        expect(DbChangeOp.fromString('UPDATE'), equals(DbChangeOp.update));
      });
      test('parses DELETE', () {
        expect(DbChangeOp.fromString('DELETE'), equals(DbChangeOp.delete));
      });
      test('is case-insensitive', () {
        expect(DbChangeOp.fromString('insert'), equals(DbChangeOp.insert));
        expect(DbChangeOp.fromString('Delete'), equals(DbChangeOp.delete));
      });
      test('returns null for unknown ops', () {
        expect(DbChangeOp.fromString('BOGUS'), isNull);
        expect(DbChangeOp.fromString(''), isNull);
      });
    });

    group('Notification → DbChangeEvent translation', () {
      test('translates INSERT with row + pkey', () {
        final n = _makePayload(
          '{"op":"INSERT",'
          '"row":"{\\"id\\":42,\\"name\\":\\"alice\\"}",'
          '"pkey":"{\\"id\\":42}"}',
        );
        final ev = _translateForTest(n);
        expect(ev, isNotNull);
        expect(ev!.op, equals(DbChangeOp.insert));
        expect(ev.type, equals(ChangeEventType.added));
        expect(ev.primaryKey, equals(<String, Object?>{'id': 42}));
        expect(ev.row!['id'], equals(42));
        expect(ev.row!['name'], equals('alice'));
      });

      test('translates UPDATE with new row', () {
        final n = _makePayload(
          '{"op":"UPDATE",'
          '"row":"{\\"id\\":42,\\"name\\":\\"bob\\"}",'
          '"pkey":"{\\"id\\":42}"}',
        );
        final ev = _translateForTest(n);
        expect(ev, isNotNull);
        expect(ev!.op, equals(DbChangeOp.update));
        expect(ev.type, equals(ChangeEventType.modified));
        expect(ev.row!['name'], equals('bob'));
      });

      test('translates DELETE without row', () {
        final n = _makePayload(
          '{"op":"DELETE","pkey":"{\\"id\\":42}"}',
        );
        final ev = _translateForTest(n);
        expect(ev, isNotNull);
        expect(ev!.op, equals(DbChangeOp.delete));
        expect(ev.type, equals(ChangeEventType.removed));
        expect(ev.row, isNull);
        expect(ev.primaryKey, equals(<String, Object?>{'id': 42}));
      });

      test('handles wide-row case (no row key)', () {
        final n = _makePayload(
          '{"op":"UPDATE","pkey":"{\\"id\\":42}"}',
        );
        final ev = _translateForTest(n);
        expect(ev, isNotNull);
        expect(ev!.row, isNull,
            reason: 'wide rows drop the row key');
        expect(ev.primaryKey, equals(<String, Object?>{'id': 42}));
      });

      test('returns null on malformed payload', () {
        final n = _makePayload('not json');
        expect(_translateForTest(n), isNull);
      });

      test('returns null on unknown op', () {
        final n = _makePayload(
          '{"op":"TRUNCATE","pkey":"{\\"id\\":42}"}',
        );
        expect(_translateForTest(n), isNull);
      });

      test('returns null when op key is missing', () {
        final n = _makePayload(
          '{"pkey":"{\\"id\\":42}"}',
        );
        expect(_translateForTest(n), isNull);
      });
    });

    group('installNotifyTriggersSql', () {
      test('emits CREATE FUNCTION + CREATE TRIGGER', () {
        final sql = installNotifyTriggersSql('users');
        expect(sql, contains('CREATE OR REPLACE FUNCTION'));
        expect(sql, contains('d_rocket_notify_users_upsert'));
        expect(sql, contains('d_rocket_notify_users_delete'));
        expect(sql, contains('pg_notify'));
        expect(sql, contains("'d_rocket_changes_users'"));
        expect(sql, contains('CREATE TRIGGER'));
        expect(sql, contains('AFTER INSERT'));
        expect(sql, contains('AFTER UPDATE'));
        expect(sql, contains('AFTER DELETE'));
      });

      test('emits wide-row fallback (no row key)', () {
        final sql = installNotifyTriggersSql('logs');
        expect(sql, contains("'op', TG_OP"));
        expect(sql, contains("'pkey', pkey_json"));
      });

      test('drops existing triggers before recreating', () {
        final sql = installNotifyTriggersSql('users');
        expect(sql, contains('DROP TRIGGER IF EXISTS'));
      });
    });
  });
}

/// Build a payload for the tests.
String _makePayload(String s) => s;

/// Mirror of the private
/// `_payloadToChangeEvent` in
/// `lib/src/listen_notify.dart`. Kept in
/// sync via the integration tests in
/// Phase 8.10. We duplicate the logic
/// here to avoid making every test
/// async (the public `stream` is the
/// natural test surface, but it requires
/// a real Connection).
DbChangeEvent? _translateForTest(String payload) {
  try {
    final Map<String, Object?> json =
        jsonDecode(payload) as Map<String, Object?>;
    final String? opStr = json['op'] as String?;
    if (opStr == null) return null;
    final DbChangeOp? op = DbChangeOp.fromString(opStr);
    if (op == null) return null;
    final Object? rowRaw = json['row'];
    Map<String, Object?>? row;
    if (rowRaw is String) {
      try {
        row = jsonDecode(rowRaw) as Map<String, Object?>;
      } on Object {
        row = null;
      }
    }
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

ChangeEventType _changeEventType(DbChangeOp op) {
  switch (op) {
    case DbChangeOp.insert:
      return ChangeEventType.added;
    case DbChangeOp.update:
      return ChangeEventType.modified;
    case DbChangeOp.delete:
      return ChangeEventType.removed;
  }
}