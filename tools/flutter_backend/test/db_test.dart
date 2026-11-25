import 'dart:convert';

import 'package:flutter_backend/src/db.dart';
import 'package:test/test.dart';

void main() {
  late LocalDb db;

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
  });

  tearDown(() => db.close());

  test('migration creates settings and persists key/value', () {
    db.setSetting('booted', '2026-11-25T00:00:00Z');
    expect(db.getSetting('booted'), '2026-11-25T00:00:00Z');
  });

  test('settings update in place, no dup rows', () {
    db.setSetting('k', 'a');
    db.setSetting('k', 'b');
    expect(db.getSetting('k'), 'b');
    final rows = db.db.select('SELECT COUNT(*) AS n FROM settings');
    expect(rows.first['n'], 1);
  });

  test('missing setting returns null', () {
    expect(db.getSetting('nope'), isNull);
  });

  test('setting stores UTF-8 JSON bytes', () {
    db.setSetting('cfg', jsonEncode({'zh': '小蜗'}));
    final raw = db.db.select('SELECT value FROM settings WHERE key=?', ['cfg']);
    expect(jsonDecode(raw.first['value'] as String), {'zh': '小蜗'});
  });
}