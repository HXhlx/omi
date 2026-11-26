import 'dart:convert';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/llm_client.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeLlm extends LlmClient {
  _FakeLlm(this._fails) : super(upstream: 'http://unused');
  final bool Function() _fails;
  List<Map<String, String>>? lastMessages;

  @override
  Future<LlmReply> complete(List<Map<String, String>> messages,
      {String? model, double? temperature}) async {
    lastMessages = messages;
    if (_fails()) throw LlmException('boom');
    return LlmReply(content: '你好，我是小蜗。', model: model ?? 'deepseek-flash');
  }

  @override
  Stream<String> stream(List<Map<String, String>> messages,
      {String? model, double? temperature}) async* {
    lastMessages = messages;
    if (_fails()) throw LlmException('boom');
    yield '你好';
    yield '，小蜗';
  }
}

void main() {
  late LocalDb db;
  late Handler handler;
  late _FakeLlm fakeLlm;
  var shouldFail = false;

  Future<Map<String, dynamic>> send(String method, String path,
      {Object? body}) async {
    final req = Request(method, Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'});
    final res = await handler(req);
    final text = await res.readAsString();
    return {
      'status': res.statusCode,
      'text': text,
      'body': text.isEmpty ? null : _tryJson(text),
    };
  }

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
    shouldFail = false;
    fakeLlm = _FakeLlm(() => shouldFail);
    handler = Api(db, llm: fakeLlm).handler;
  });

  tearDown(() => db.close());

  test('desktop chat completions returns OpenAI shape', () async {
    final r = await send('POST', '/v2/chat/completions', body: {
      'model': 'deepseek-flash',
      'stream': false,
      'messages': [
        {'role': 'user', 'content': '嗨'}
      ],
    });
    expect(r['status'], 200);
    final body = r['body'] as Map;
    final choice = (body['choices'] as List).first as Map;
    expect(((choice['message'] as Map)['content']), '你好，我是小蜗。');
    expect(fakeLlm.lastMessages!.last['content'], '嗨');
  });

  test('desktop chat completions maps LLM failure to 502', () async {
    shouldFail = true;
    final r = await send('POST', '/v2/chat/completions', body: {
      'messages': [
        {'role': 'user', 'content': 'x'}
      ],
    });
    expect(r['status'], 502);
  });

  test('v2/messages rejects empty text', () async {
    final r = await send('POST', '/v2/messages', body: {'text': '  '});
    expect(r['status'], 400);
  });

  test('v2/messages streams data frames and persists both turns', () async {
    final r = await send('POST', '/v2/messages', body: {'text': '你好'});
    expect(r['status'], 200);
    final text = r['text'] as String;
    expect(text, contains('data: '));
    expect(text, contains('done: '));
    final history = await send('GET', '/v2/messages');
    final list = history['body'] as List;
    expect(list.length, 2);
    expect((list[0] as Map)['sender'], 'user');
    expect((list[1] as Map)['sender'], 'ai');
  });

  test('chat sessions create/list/get/patch/delete', () async {
    final created = await send('POST', '/v2/chat-sessions', body: {'title': '会话一'});
    final id = (created['body'] as Map)['id'] as String;
    expect(((await send('GET', '/v2/chat-sessions'))['body'] as List).length, 1);
    expect(((await send('GET', '/v2/chat-sessions/$id'))['body'] as Map)['title'], '会话一');
    final patched = await send('PATCH', '/v2/chat-sessions/$id', body: {'starred': true});
    expect((patched['body'] as Map)['starred'], true);
    await send('DELETE', '/v2/chat-sessions/$id');
    expect((await send('GET', '/v2/chat-sessions/$id'))['status'], 404);
  });
}

dynamic _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}