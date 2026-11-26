import 'dart:convert';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/llm_client.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeLlm extends LlmClient {
  _FakeLlm() : super(upstream: 'http://unused');
  @override
  Future<LlmReply> complete(List<Map<String, String>> messages,
          {String? model, double? temperature}) async =>
      LlmReply(content: jsonEncode(['用户喜欢喝茶']));
}

void main() {
  late LocalDb db;
  late Handler handler;

  Future<Map<String, dynamic>> send(String method, String path,
      {Object? body}) async {
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
    handler = Api(db, llm: _FakeLlm()).handler;
  });

  tearDown(() => db.close());

  test('sync capture manifest returns a manifest envelope', () async {
    final r = await send('POST', '/v2/sync-capture-manifest', body: {
      'conversation_id': 'c1',
      'files': [
        {'name': 'a.pcm', 'size': 128},
      ],
    });
    expect(r['status'], 200);
    final manifest = jsonDecode((r['body'] as Map)['manifest'] as String) as Map;
    expect(manifest['conversation_id'], 'c1');
    expect(manifest['accepted_files'], 1);
  });

  test('sync capture end accepts and does not ask retry', () async {
    final r = await send('POST', '/v2/sync-capture-end', body: {
      'recording_session_id': 's1',
      'end_type': 'user_stop',
      'end_decided_at': 1,
      'sent_at': 2,
      'pending_wals': 0,
    });
    expect(r['status'], 200);
    expect((r['body'] as Map)['accepted'], true);
    expect((r['body'] as Map)['retry'], false);
  });

  test('sync-local-files queues a job and reports completed', () async {
    final r = await send('POST', '/v2/sync-local-files', body: {});
    expect((r['body'] as Map)['status'], 'queued');
    final job = (await send(
            'GET', '/v2/sync-local-files/${(r['body'] as Map)['job_id']}'))['body']
        as Map;
    expect(job['status'], 'completed');
  });

  test('desktop messages persist and clear', () async {
    await send('POST', '/v2/desktop/messages', body: {'text': '你好'});
    final list = (await send('GET', '/v2/desktop/messages'))['body'] as List;
    expect(list.length, 1);
    await send('DELETE', '/v2/desktop/messages');
    expect(((await send('GET', '/v2/desktop/messages'))['body'] as List), isEmpty);
  });

  test('memories extract runs LLM and stores facts', () async {
    final r = await send('POST', '/v1/memories/extract',
        body: {'text': '我每天喝三杯茶'});
    expect(r['status'], 200);
    final mems = (r['body'] as Map)['memories'] as List;
    expect(mems.length, 1);
    expect(((mems.first as Map)['content']), '用户喜欢喝茶');
    expect(((await send('GET', '/v3/memories'))['body'] as List).length, 1);
  });

  test('realtime session mints an inert local token', () async {
    final r = await send('POST', '/v2/realtime/session?provider=local');
    expect(r['status'], 200);
    final body = r['body'] as Map;
    expect(body['session_id'], isNotEmpty);
    expect(body['client_secret'], isA<Map>());
  });

  test('gemini proxy returns candidates shape', () async {
    final r = await send('POST', '/v1/proxy/gemini/models/x:generateContent',
        body: {
      'contents': [
        {
          'parts': [
            {'text': '你好'}
          ]
        }
      ]
    });
    expect(r['status'], 200);
    final candidates = (r['body'] as Map)['candidates'] as List;
    final parts = (((candidates.first as Map)['content'] as Map)['parts'] as List);
    expect(((parts.first as Map)['text']), isNotEmpty);
  });

  test('gemini embedding returns a fixed-dim vector', () async {
    final r = await send('POST', '/v1/proxy/gemini/models/x:embedContent', body: {});
    final embedding = ((r['body'] as Map)['embedding'] as Map)['values'] as List;
    expect(embedding.length, 1024);
  });

  test('apps list and enabled ids', () async {
    final apps = (await send('GET', '/v1/apps'))['body'] as List;
    expect(apps, isNotEmpty);
    final enabled = (await send('GET', '/v1/apps/enabled'))['body'] as List;
    expect(enabled, isNotEmpty);
    final catalog = (await send('GET', '/v2/apps'))['body'] as Map;
    expect((catalog['data'] as List), isNotEmpty);
  });

  test('search overview counts stored memories', () async {
    await send('POST', '/v3/memories', body: {'content': 'a'});
    final ov = (await send('GET', '/v1/search/overview'))['body'] as Map;
    expect(ov['memories'], 1);
  });

  test('home feed returns memory items', () async {
    await send('POST', '/v3/memories', body: {'content': 'b'});
    final feed = (await send('GET', '/v1/home/feed'))['body'] as Map;
    expect((feed['items'] as List).length, 1);
  });

  test('subscription/quota/trial are local-unlimited', () async {
    final sub = (await send('GET', '/v1/users/me/subscription'))['body'] as Map;
    expect(sub['plan'], 'local');
    final quota = (await send('GET', '/v1/users/me/usage-quota'))['body'] as Map;
    expect(quota['unlimited'], true);
    expect(((await send('GET', '/v1/users/me/trial'))['body'] as Map)['active'], false);
  });
}

dynamic _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}