import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'provider_surfaces.dart';
import 'tts.dart';

/// Synthesizes speech through an adjacent OpenAI-compatible TTS worker
/// (speaches: `POST /v1/audio/speech` with `{model, input, voice}`). Returns
/// MP3 bytes. The local worker is expected on [upstream].
class TtsClient implements TtsSurface {
  TtsClient({http.Client? client, this.upstream = kDefaultTtsUpstream}) : _client = client ?? http.Client();

  final http.Client _client;
  final String upstream;

  @override
  Future<Uint8List> synthesize(TtsRequest req) async {
    final uri = Uri.parse('$upstream/v1/audio/speech');
    final res = await _client.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'model': req.voiceId ?? kDefaultAssistantVoice,
        'input': req.text,
        'voice': req.voiceId ?? kDefaultAssistantVoice,
        'response_format': 'mp3',
      }),
    );
    if (res.statusCode != 200) {
      throw TtsException('upstream ${res.statusCode}: ${res.body}');
    }
    return res.bodyBytes;
  }

  void close() => _client.close();
}

class TtsException implements Exception {
  TtsException(this.message);
  final String message;
  @override
  String toString() => 'TtsException: $message';
}
