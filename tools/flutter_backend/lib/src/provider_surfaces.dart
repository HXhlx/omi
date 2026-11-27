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

/// On-device sentence embedding: texts in, one vector per text out. The
/// vector dimension is the engine's (768 for bge-base-zh, 512 for small,
/// 1024 for Qwen3-Embedding); consumers compute cosine similarity directly.
abstract class EmbedSurface {
  Future<List<List<double>>> embed(List<String> texts);
}
