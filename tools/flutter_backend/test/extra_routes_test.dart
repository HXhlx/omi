import 'dart:convert';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late LocalDb db;
  late Handler handler;

  Future<Map<String, dynamic>> send(String method, String path, {Object? body}) async {
    final req = Request(method, Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'});
    final res = await handler(req);
    final text = await res.readAsString();
    return {
      'status': res.statusCode,
      'body': text.isEmpty ? null : _tryJson(text),
    };
  }

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
    handler = Api(db).handler;
  });

  tearDown(() => db.close());

  test('static sub-resources that collide with param routes resolve', () async {
    expect((await send('GET', '/v1/action-items/ids'))['status'], 200);
    expect((await send('GET', '/v1/goals/canonical'))['status'], 200);
    expect((await send('GET', '/v1/conversations/live'))['status'], 200);
  });

  test('unknown path is still 404', () async {
    expect((await send('GET', '/nope'))['status'], 404);
    expect((await send('GET', '/v1/definitely-not-a-route'))['status'], 404);
  });

  test('missing conversation finalize is still 404', () async {
    expect((await send('POST', '/v1/conversations/nope/finalize'))['status'], 404);
    expect((await send('POST', '/v1/conversations/nope/reprocess'))['status'], 404);
  });

  test('long-tail stubs answer 200', () async {
    for (final p in [
      '/v1/announcements',
      '/v2/firmware/latest',
      '/v1/review/items',
      '/v1/screen-activity',
      '/v1/speaker-tag-prompts',
      '/v1/calendar/meetings',
      '/v1/dev/keys',
      '/v1/mcp',
      '/v1/mobile/feedback',
    ]) {
      expect((await send('GET', p))['status'], 200, reason: p);
    }
  });

  test('conversation summary defaults without a transcript', () async {
    final created = await send('POST', '/v1/conversations/from-segments', body: {
      'transcript_segments': [
        {'text': 'a', 'is_user': true, 'start': 0.0, 'end': 1.0},
      ],
    });
    final id = ((created['body'] as Map)['id']) as String;
    expect((await send('GET', '/v1/conversations/$id/segments/text'))['status'], 200);
    expect((await send('GET', '/v1/conversations/$id/summary'))['status'], 200);
  });

  test('external sync + tools return 200', () async {
    expect((await send('GET', '/v1/sync/audio/x/urls'))['status'], 200);
    expect((await send('GET', '/v1/knowledge-graph'))['status'], 200);
    expect((await send('GET', '/v1/agent/tools'))['status'], 200);
  });
}

dynamic _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}