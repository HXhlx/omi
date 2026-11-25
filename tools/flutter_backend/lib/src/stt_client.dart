import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const kDefaultSttUpstream = 'http://127.0.0.1:8200';

/// Result shape the local STT worker (`omi_stt_server.py` / `omi_funasr_server.py`)
/// returns from `POST /v1/transcribe`:
/// `{text, segments:[{start,end,text,speaker}], detected_language}`.
class SttResult {
  SttResult({
    required this.text,
    required this.segments,
    this.language,
  });

  factory SttResult.fromJson(Map<String, dynamic> j) => SttResult(
        text: j['text'] as String? ?? '',
        segments: (j['segments'] as List?)
                ?.map((e) => SttSegment.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        language: j['detected_language'] as String?,
      );

  final String text;
  final List<SttSegment> segments;
  final String? language;
}

class SttSegment {
  SttSegment({
    required this.text,
    required this.start,
    required this.end,
    this.speaker,
  });

  factory SttSegment.fromJson(Map<String, dynamic> j) => SttSegment(
        text: j['text'] as String? ?? '',
        start: (j['start'] as num?)?.toDouble() ?? 0,
        end: (j['end'] as num?)?.toDouble() ?? 0,
        speaker: j['speaker'] as String?,
      );

  final String text;
  final double start;
  final double end;
  final String? speaker;

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': start,
        'end': end,
        if (speaker != null) 'speaker': speaker,
      };
}

/// Transcribes audio through an adjacent local STT worker. The worker accepts
/// multipart `file=`, so this client encodes any audio buffer as a WAV part.
class SttClient {
  SttClient({http.Client? client, this.upstream = kDefaultSttUpstream})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String upstream;

  Future<SttResult> transcribe(Uint8List audio,
      {String? language, String filename = 'audio.wav'}) async {
    final request = http.MultipartRequest('POST', Uri.parse('$upstream/v1/transcribe'))
      ..files.add(http.MultipartFile.fromBytes('file', audio, filename: filename));
    if (language != null) request.fields['language'] = language;
    final streamed = await _client.send(request);
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw SttException('upstream ${streamed.statusCode}: $body');
    }
    return SttResult.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// Wraps a PCM16 buffer into a minimal RIFF/WAV container so worker decoders
  /// that sniff by suffix see a valid file.
  Future<SttResult> transcribePcm(
    Uint8List pcm16, {
    int sampleRate = 16000,
    int channels = 1,
    String? language,
  }) =>
      transcribe(_wrapWav(pcm16, sampleRate: sampleRate, channels: channels),
          language: language, filename: 'audio.wav');

  /// Forward a client-authored multipart body unchanged (mobile uploads a
  /// `file=` part the worker already understands).
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType) async {
    final res = await _client.post(
      Uri.parse('$upstream/v1/transcribe'),
      headers: {'content-type': contentType},
      body: body,
    );
    if (res.statusCode != 200) {
      throw SttException('upstream ${res.statusCode}: ${res.body}');
    }
    return SttResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void close() => _client.close();

  /// Test seam: expose WAV wrapping so tests assert the container, not a copy.
  static Uint8List wrapWavForTest(Uint8List pcm,
          {int sampleRate = 16000, int channels = 1}) =>
      _wrapWav(pcm, sampleRate: sampleRate, channels: channels);

  /// 44-byte canonical RIFF header + PCM16 LE payload.
  static Uint8List _wrapWav(Uint8List pcm, {int sampleRate = 16000, int channels = 1}) {
    final byteRate = sampleRate * channels * 2;
    final dataSize = pcm.length;
    final header = Uint8List(44);
    void putString(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header[offset + i] = s.codeUnitAt(i);
      }
    }

    void putU32(int offset, int v) => header.buffer.asByteData().setUint32(offset, v, Endian.little);
    void putU16(int offset, int v) => header.buffer.asByteData().setUint16(offset, v, Endian.little);

    putString(0, 'RIFF');
    putU32(4, 36 + dataSize);
    putString(8, 'WAVE');
    putString(12, 'fmt ');
    putU32(16, 16);
    putU16(20, 1); // PCM
    putU16(22, channels);
    putU32(24, sampleRate);
    putU32(28, byteRate);
    putU16(32, channels * 2);
    putU16(34, 16);
    putString(36, 'data');
    putU32(40, dataSize);
    final out = Uint8List(44 + dataSize)
      ..setRange(0, 44, header)
      ..setRange(44, 44 + dataSize, pcm);
    return out;
  }
}

class SttException implements Exception {
  SttException(this.message);
  final String message;
  @override
  String toString() => 'SttException: $message';
}