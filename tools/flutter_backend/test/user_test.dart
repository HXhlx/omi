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

  Future<Map<String, dynamic>> get(String p) => send('GET', p);

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
    handler = Api(db).handler;
  });

  tearDown(() => db.close());

  test('profile returns local user', () async {
    final p = (await get('/v1/users/profile'))['body'] as Map;
    expect(p['uid'], 'local-dev-user');
    expect(p['name'], isNotEmpty);
    expect(p['data_protection_level'], 'local');
  });

  test('ai profile get/patch returns a versioned doc', () async {
    await send('PATCH', '/v1/users/ai-profile', body: {'profile_text': '喜欢无障碍产品'});
    final p = (await get('/v1/users/ai-profile'))['body'] as Map;
    expect(p['profile_text'], '喜欢无障碍产品');
    expect(p['version'], 1);
  });

  test('people create/list/delete', () async {
    final created = await send('POST', '/v1/users/people', body: {'name': '王小明'});
    final id = (created['body'] as Map)['id'] as String;
    expect(((await get('/v1/users/people'))['body'] as List).length, 1);
    await send('DELETE', '/v1/users/people/$id');
    expect(((await get('/v1/users/people'))['body'] as List), isEmpty);
  });

  test('goals: get empty, create, list-all, mark inactive', () async {
    expect((await get('/v1/goals'))['body'], isNull);
    final created = await send('POST', '/v1/goals', body: {'title': '每周运动三次'});
    final id = ((created['body'] as Map)['id']) as String;
    expect(((await get('/v1/goals'))['body'] as Map)['title'], '每周运动三次');
    expect(((await get('/v1/goals/all'))['body'] as List).length, 1);
    await send('PATCH', '/v1/goals/$id', body: {'status': 'completed'});
    expect((await get('/v1/goals'))['body'], isNull);
  });

  test('folders create/list/patch/delete', () async {
    final created = await send('POST', '/v1/folders', body: {'name': '工作'});
    final id = ((created['body'] as Map)['id']) as String;
    expect(((await get('/v1/folders'))['body'] as List).length, 1);
    final patched = await send('PATCH', '/v1/folders/$id', body: {'color': '#ff0000'});
    expect((patched['body'] as Map)['color'], '#ff0000');
    await send('DELETE', '/v1/folders/$id');
    expect(((await get('/v1/folders'))['body'] as List), isEmpty);
  });

  test('daily summary is built from conversations that day', () async {
    final sum = await send('POST', '/v1/users/daily-summaries', body: {'date': '2026-11-25'});
    expect(sum['status'], 200);
    final body = sum['body'] as Map;
    expect(body['date'], '2026-11-25');
    expect(body['headline'], isNotEmpty);
  });

  test('flags return empty map', () async {
    final f = (await get('/v1/flags'))['body'] as Map;
    expect(f['flags'], isA<Map>());
  });
}

dynamic _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}