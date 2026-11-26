/// Minimal surfaces the provider router and its consumers share.
///
/// Kept separate from `provider_router.dart` so the concrete clients can
/// implement them without importing the router (avoids an import cycle).
library;

import 'dart:typed_data';

import 'llm_client.dart';
import 'stt_client.dart';
import 'tts.dart';

abstract class LlmSurface {
  Future<LlmReply> complete(List<Map<String, String>> messages, {String? model, double? temperature});
  Stream<String> stream(List<Map<String, String>> messages, {String? model, double? temperature});
}

abstract class SttSurface {
  Future<SttResult> transcribePcm(Uint8List pcm16, {int sampleRate, int channels, String? language});
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType);
}

abstract class TtsSurface {
  Future<Uint8List> synthesize(TtsRequest req);
}
