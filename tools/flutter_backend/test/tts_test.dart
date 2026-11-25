import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:flutter_backend/src/tts.dart';
import 'package:flutter_backend/src/tts_client.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeTts extends TtsClient {
  _FakeTts(this._fails) : super(upstream: 'http://unused');
  final bool Function() _fails;

  @override
  Future<Uint8List> synthesize(TtsRequest req) async {
    if (_fails()) throw TtsException('boom');
    return Uint8List.fromList(List<int>.generate(64, (i) => i & 0xff));
  }
}

void main() {
  late LocalDb db;
  late Handler handler;
  var shouldFail = false;

  Future<Map<String, dynamic>> send(String method, String path, {Object? body}) async {
    final req = Request(method, Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'});
    final res = await handler(req);
    final bytes = <int>[];
    await for (final chunk in res.read()) {
      bytes.addAll(chunk);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      decoded = null;
    }
    return {
      'status': res.statusCode,
      'body': decoded,
      'bytes': bytes,
      'contentType': res.headers['content-type'],
    };
  }

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
    shouldFail = false;
    handler = Api(db, tts: _FakeTts(() => shouldFail)).handler;
  });

  tearDown(() => db.close());

  test('voices returns a catalog with default_voice_id', () async {
    final r = await send('GET', '/v1/tts/voices');
    expect(r['status'], 200);
    final body = r['body'] as Map;
    expect(body['voices'], isNotEmpty);
    expect(body['default_voice_id'], isNotEmpty);
  });

  test('get user voice returns a non-empty id', () async {
    final r = await send('GET', '/v1/users/voice');
    expect(r['status'], 200);
    expect((r['body'] as Map)['voice_id'], isNotEmpty);
  });

  test('patch user voice persists', () async {
    await send('PATCH', '/v1/users/voice', body: {'voice_id': 'edge-zh-CN-XiaoxiaoNeural'});
    final r = await send('GET', '/v1/users/voice');
    expect((r['body'] as Map)['voice_id'], 'edge-zh-CN-XiaoxiaoNeural');
  });

  test('tts synthesize returns audio/mpeg bytes', () async {
    final r = await send('POST', '/v2/tts/synthesize',
        body: {'text': '你好，小蜗', 'voice_id': 'xv'});
    expect(r['status'], 200);
    expect(r['contentType'], contains('audio/mpeg'));
    expect((r['bytes'] as List<int>).length, greaterThan(0));
  });

  test('tts synthesize rejects empty text', () async {
    final r = await send('POST', '/v2/tts/synthesize', body: {'text': '  '});
    expect(r['status'], 400);
  });

  test('tts synthesize rejects oversized text', () async {
    final r = await send('POST', '/v2/tts/synthesize', body: {'text': 'a' * 5001});
    expect(r['status'], 400);
  });

  test('tts synthesize maps upstream failure to 503', () async {
    shouldFail = true;
    final r = await send('POST', '/v2/tts/synthesize', body: {'text': 'hi'});
    expect(r['status'], 503);
  });

  test('v1/tts/synthesize alias also serves mpeg', () async {
    final r = await send('POST', '/v1/tts/synthesize', body: {'text': 'hi'});
    expect(r['status'], 200);
    expect(r['contentType'], contains('audio/mpeg'));
  });
}