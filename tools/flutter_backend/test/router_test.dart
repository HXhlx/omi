import 'dart:convert';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late LocalDb db;
  late Handler handler;

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
    handler = Api(db).handler;
  });

  tearDown(() => db.close());

  Future<Map<String, dynamic>> request_(
      String method, String path, {Object? body}) async {
    final req = Request(method, Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'});
    final res = await handler(req);
    final text = await res.readAsString();
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return {'status': res.statusCode, 'body': decoded};
  }

  Future<Map<String, dynamic>> get(String p) => request_('GET', p);
  Future<Map<String, dynamic>> post(String p, {Object? body}) =>
      request_('POST', p, body: body);
  Future<Map<String, dynamic>> patch(String p, {Object? body}) =>
      request_('PATCH', p, body: body);
  Future<Map<String, dynamic>> del(String p) => request_('DELETE', p);

  test('health and v1/health answer', () async {
    expect((await get('/health'))['status'], 200);
    expect((await get('/v1/health'))['status'], 200);
  });

  test('unknown path returns FastAPI-style 404 detail', () async {
    final r = await get('/nope');
    expect(r['status'], 404);
    expect((r['body'] as Map)['detail'], 'Not Found');
  });

  test('list conversations is empty then non-empty after create', () async {
    expect(((await get('/v1/conversations'))['body'] as List), isEmpty);
    await post('/v1/conversations/from-segments', body: {
      'source': 'desktop',
      'language': 'zh',
      'transcript_segments': [
        {'text': '你好', 'is_user': true, 'start': 0.0, 'end': 1.0},
        {'text': '今天开会', 'is_user': false, 'start': 1.0, 'end': 2.0, 'speaker': 'SPEAKER_01'},
      ],
    });
    final list = ((await get('/v1/conversations'))['body'] as List);
    expect(list.length, 1);
    final c = list.first as Map<String, dynamic>;
    expect(c['language'], 'zh');
    expect(c['status'], 'completed');
    // List responses omit the transcript; detail responses carry it.
    final id = c['id'] as String;
    final detail = ((await get('/v1/conversations/$id'))['body'] as Map);
    expect((detail['transcript'] as List).length, 2);
  });

  test('from-segments returned id is fetchable and has transcript', () async {
    final created = await post('/v1/conversations/from-segments', body: {
      'transcript_segments': [
        {'text': 'a', 'is_user': true, 'start': 0.0, 'end': 1.0},
      ],
    });
    final id = (created['body'] as Map)['id'] as String;
    final got = await get('/v1/conversations/$id');
    expect(got['status'], 200);
    final body = got['body'] as Map;
    expect(body['id'], id);
    expect((body['transcript'] as List).length, 1);
  });

  test('delete removes conversation', () async {
    final created = await post('/v1/conversations/from-segments', body: {
      'transcript_segments': [
        {'text': 'a', 'is_user': true, 'start': 0.0, 'end': 1.0},
      ],
    });
    final id = (created['body'] as Map)['id'] as String;
    expect((await del('/v1/conversations/$id'))['status'], 204);
    expect((await get('/v1/conversations/$id'))['status'], 404);
  });

  test('patch title persists', () async {
    final created = await post('/v1/conversations/from-segments', body: {
      'transcript_segments': [
        {'text': 'a', 'is_user': true, 'start': 0.0, 'end': 1.0},
      ],
    });
    final id = ((created['body'] as Map)['id']) as String;
    final r = await patch('/v1/conversations/$id/title', body: {'title': '周会'});
    expect(r['status'], 200);
    final got = (await get('/v1/conversations/$id'))['body'] as Map;
    expect(got['title'], '周会');
  });

  test('conversation count reflects rows', () async {
    expect(((await get('/v1/conversations/count'))['body'] as Map)['count'], 0);
    await post('/v1/conversations/from-segments', body: {
      'transcript_segments': [
        {'text': 'a', 'is_user': true, 'start': 0.0, 'end': 1.0},
      ],
    });
    expect(((await get('/v1/conversations/count'))['body'] as Map)['count'], 1);
  });
}