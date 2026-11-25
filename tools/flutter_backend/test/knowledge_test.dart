import 'dart:convert';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/llm_client.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Canned LLM: notes JSON for the prompt with `{`, facts array for `[`.
class _CannedLlm extends LlmClient {
  _CannedLlm() : super(upstream: 'http://unused');
  var calls = 0;

  @override
  Future<LlmReply> complete(List<Map<String, String>> messages,
      {String? model, double? temperature}) async {
    calls++;
    final system = messages.first['content'] ?? '';
    if (system.contains('"action_items"')) {
      return LlmReply(content: jsonEncode({
        'title': '周会',
        'overview': '讨论了排期。',
        'action_items': ['周五前提交报告'],
      }));
    }
    return LlmReply(content: jsonEncode(['用户关注无障碍产品', '用户在准备周会']));
  }
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
    handler = Api(db, llm: _CannedLlm()).handler;
  });

  tearDown(() => db.close());

  test('create + list + edit + delete memory', () async {
    final created = await send('POST', '/v3/memories',
        body: {'content': '用户喜欢喝茶'});
    expect(created['status'], 200);
    final id = (created['body'] as Map)['id'] as String;

    final list = (await send('GET', '/v3/memories'))['body'] as List;
    expect(list.length, 1);
    expect((list.first as Map)['content'], '用户喜欢喝茶');

    await send('PATCH', '/v3/memories/$id', body: {'content': '用户改喝茶'});
    final list2 = (await send('GET', '/v3/memories'))['body'] as List;
    expect((list2.first as Map)['content'], '用户改喝茶');

    await send('DELETE', '/v3/memories/$id');
    expect(((await send('GET', '/v3/memories'))['body'] as List), isEmpty);
  });

  test('memory search matches substring', () async {
    await send('POST', '/v3/memories', body: {'content': '用户养了一只猫叫团子'});
    final hits = (await send('GET', '/memory/search?query=猫'))['body'] as Map;
    expect((hits['items'] as List).length, 1);
  });

  test('batch create memories', () async {
    final r = await send('POST', '/v3/memories/batch', body: {
      'memories': [
        {'content': 'a'},
        {'content': 'b'},
      ],
    });
    expect((r['body'] as Map)['created'], 2);
    expect(((await send('GET', '/v3/memories'))['body'] as List).length, 2);
  });

  test('action items create/list/patch-complete/delete', () async {
    final created = await send('POST', '/v1/action-items',
        body: {'description': '提交周报'});
    final id = ((created['body'] as Map)['id']) as String;
    expect((created['body'] as Map)['completed'], false);

    final listed = (await send('GET', '/v1/action-items'))['body'] as Map;
    expect((listed['action_items'] as List).length, 1);
    expect(listed['has_more'], false);

    final patched = await send('PATCH', '/v1/action-items/$id',
        body: {'completed': true});
    expect((patched['body'] as Map)['completed'], true);

    await send('DELETE', '/v1/action-items/$id');
    expect(((await send('GET', '/v1/action-items'))['body'] as Map)['action_items'],
        isEmpty);
  });

  test('finalize runs pipeline: notes title, memories, action items', () async {
    final created = await send('POST', '/v1/conversations/from-segments', body: {
      'transcript_segments': [
        {'text': '周五前要交报告', 'is_user': true, 'start': 0.0, 'end': 2.0},
      ],
    });
    final id = ((created['body'] as Map)['id']) as String;

    final fin = await send('POST', '/v1/conversations/$id/finalize');
    expect(fin['status'], 200);
    final pipeline = (fin['body'] as Map)['pipeline'] as Map;
    expect(pipeline['processed'], true);
    expect(pipeline['memories'], 2);
    expect(pipeline['action_items'], 1);

    // Conversation title came from the notes.
    final detail = (await send('GET', '/v1/conversations/$id'))['body'] as Map;
    expect(detail['title'], '周会');

    // Derived knowledge landed.
    expect(((await send('GET', '/v3/memories'))['body'] as List).length, 2);
    final items = (await send('GET', '/v1/action-items'))['body'] as Map;
    expect(((items['action_items'] as List).first as Map)['description'],
        '周五前提交报告');
  });

  test('finalize on missing conversation 404s', () async {
    final r = await send('POST', '/v1/conversations/nope/finalize');
    expect(r['status'], 404);
  });
}

dynamic _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}