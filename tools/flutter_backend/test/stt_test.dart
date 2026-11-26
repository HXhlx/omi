import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:flutter_backend/src/stt_client.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeStt extends SttClient {
  _FakeStt(this._fails) : super(upstream: 'http://unused');
  final bool Function() _fails;
  Uint8List? lastBody;
  String? lastContentType;

  @override
  Future<SttResult> transcribe(Uint8List audio,
      {String? language, String filename = 'audio.wav'}) async {
    if (_fails()) throw SttException('boom');
    return SttResult(
      text: '你好世界',
      language: 'zh',
      segments: [
        SttSegment(text: '你好世界', start: 0.0, end: 1.2, speaker: '00'),
      ],
    );
  }

  @override
  Future<SttResult> transcribePcm(Uint8List pcm16,
      {int sampleRate = 16000, int channels = 1, String? language}) async {
    lastBody = await _viaReal(pcm16, sampleRate: sampleRate, channels: channels);
    return transcribe(pcm16, language: language);
  }

  @override
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType) async {
    lastBody = body;
    lastContentType = contentType;
    return transcribe(body);
  }

  // Real WAV wrapping, so the RIFF header assertion tests production code.
  static Future<Uint8List> _viaReal(Uint8List pcm,
          {int sampleRate = 16000, int channels = 1}) async =>
      SttClient.wrapWavForTest(pcm, sampleRate: sampleRate, channels: channels);
}

void main() {
  late LocalDb db;
  late Handler handler;
  late _FakeStt fakeStt;
  var shouldFail = false;

  Future<Map<String, dynamic>> sendRaw(
      String method, String path, Uint8List body, String contentType) async {
    final req = Request(method, Uri.parse('http://localhost$path'),
        body: body, headers: {'content-type': contentType});
    final res = await handler(req);
    final text = await res.readAsString();
    return {
      'status': res.statusCode,
      'body': text.isEmpty ? null : jsonDecode(text),
    };
  }

  setUp(() async {
    db = LocalDb.inMemory();
    await db.migrate();
    shouldFail = false;
    fakeStt = _FakeStt(() => shouldFail);
    handler = Api(db, stt: fakeStt).handler;
  });

  tearDown(() => db.close());

  test('raw PCM transcribe returns transcript', () async {
    final pcm = Uint8List.fromList(List<int>.generate(3200, (i) => i & 0xff));
    final r = await sendRaw(
        'POST', '/v2/voice-message/transcribe?sample_rate=16000', pcm,
        'application/octet-stream');
    expect(r['status'], 200);
    final body = r['body'] as Map;
    expect(body['transcript'], '你好世界');
    expect(body['language'], 'zh');
    expect((body['segments'] as List).length, 1);
    expect(fakeStt.lastBody, isNotNull);
    expect(_riff(fakeStt.lastBody!), 'RIFF');
  });

  test('stt/transcribe rejects empty body', () async {
    final r = await sendRaw('POST', '/v1/stt/transcribe', Uint8List(0),
        'application/octet-stream');
    expect(r['status'], 400);
  });

  test('stt maps upstream failure to 503', () async {
    shouldFail = true;
    final r = await sendRaw(
        'POST', '/v1/stt/transcribe', Uint8List(640), 'application/octet-stream');
    expect(r['status'], 503);
  });

  test('multipart voice message forwards content-type and body', () async {
    final r = await sendRaw(
        'POST',
        '/v2/voice-message/transcribe',
        Uint8List.fromList(List<int>.generate(800, (i) => i & 0xff)),
        'multipart/form-data; boundary=xyz');
    expect(r['status'], 200);
    expect(fakeStt.lastContentType, contains('multipart/form-data'));
    expect(fakeStt.lastBody, isNotNull);
  });
}

String _riff(Uint8List b) =>
    b.length >= 4 ? String.fromCharCodes(b.sublist(0, 4)) : '';