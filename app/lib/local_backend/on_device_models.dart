/// On-demand model downloads for the on-device provider cards
/// (`local-whisper`, `local-sensevoice`). Nothing downloads until the user
/// picks the card on the provider-cards page; the bytes come from domestic
/// mirrors (hf-mirror.com, CN CDN; modelscope when it hosts the artifact).
///
/// Files land in `<app support>/models/` — the same tree
/// `FreemiumTranscriptionService` and the whisper surface already read.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:path_provider/path_provider.dart';

/// One downloadable artifact of an on-device card.
class OnDeviceModelFile {
  const OnDeviceModelFile(this.relativePath, this.mirrorUrls);

  /// Path under `<app support>/models/`.
  final String relativePath;

  /// Mirrors tried in order — domestic first.
  final List<String> mirrorUrls;
}

/// Catalog of on-demand models. Keep sizes honest for progress display.
const Map<String, List<OnDeviceModelFile>> kOnDeviceModels = {
  'local-whisper': [
    OnDeviceModelFile('ggml-tiny.bin', [
      'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
    ]),
  ],
  'local-sensevoice': [
    OnDeviceModelFile('sensevoice/model.int8.onnx', [
      'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
      'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
    ]),
    OnDeviceModelFile('sensevoice/tokens.txt', [
      'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
      'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
    ]),
  ],
  // Embedding engine: bge-base-zh int8 ONNX + WordPiece vocab. Default
  // selection of the local-embed card's static list.
  'local-embed': [
    OnDeviceModelFile('embed/bge-base-zh/model_int8.onnx', [
      'https://hf-mirror.com/Xenova/bge-base-zh-v1.5/resolve/main/onnx/model_int8.onnx',
      'https://huggingface.co/Xenova/bge-base-zh-v1.5/resolve/main/onnx/model_int8.onnx',
    ]),
    OnDeviceModelFile('embed/bge-base-zh/vocab.txt', [
      'https://hf-mirror.com/Xenova/bge-base-zh-v1.5/resolve/main/vocab.txt',
      'https://huggingface.co/Xenova/bge-base-zh-v1.5/resolve/main/vocab.txt',
    ]),
  ],
};

/// Human-facing sizes for the card's download prompt (bytes).
const Map<String, int> kOnDeviceModelSizeBytes = {
  'local-whisper': 77691713, // ggml tiny
  'local-sensevoice': 239549435, // model.int8.onnx + tokens.txt
  'local-embed': 102517333, // bge-base-zh int8 + vocab
};

/// Progress of one download: 0–1 per file plus the file name.
class OnDeviceModelProgress {
  const OnDeviceModelProgress({required this.file, required this.fraction});
  final String file;
  final double fraction;
}

/// Downloads all files of [channelId]'s model into the app's models dir,
/// reporting per-file progress. Throws [HttpException] on total failure
/// (every mirror refused). Returns total bytes written.
Future<int> downloadOnDeviceModel(
  String channelId, {
  required void Function(OnDeviceModelProgress) onProgress,
  http.Client? client,
}) async {
  final files = kOnDeviceModels[channelId];
  if (files == null) throw ArgumentError('no on-demand model for $channelId');
  final support = await getApplicationSupportDirectory();
  final modelsDir = Directory('${support.path}/models');
  await modelsDir.create(recursive: true);
  final c = client ?? http.Client();
  var totalBytes = 0;
  try {
    for (final f in files) {
      final target = File('${modelsDir.path}/${f.relativePath}');
      await target.parent.create(recursive: true);
      Object? lastErr;
      var saved = false;
      for (final url in f.mirrorUrls) {
        try {
          final res = await c.send(http.Request('GET', Uri.parse(url)));
          if (res.statusCode != 200) {
            lastErr = HttpException('${res.statusCode} from $url');
            continue;
          }
          final total = res.contentLength ?? 0;
          var received = 0;
          final sink = target.openWrite();
          try {
            await for (final chunk in res.stream) {
              sink.add(chunk);
              received += chunk.length;
              if (total > 0) {
                onProgress(OnDeviceModelProgress(
                  file: f.relativePath,
                  fraction: received / total,
                ));
              }
            }
            await sink.flush();
            await sink.close();
          } catch (e) {
            await sink.close().catchError((_) {});
            rethrow;
          }
          totalBytes += received;
          saved = true;
          break;
        } catch (e) {
          lastErr = e;
        }
      }
      if (!saved) {
        // Clean the partial file so `isDownloaded` never sees a stub.
        if (await target.exists()) await target.delete();
        throw HttpException('download failed for ${f.relativePath}: $lastErr');
      }
    }
  } finally {
    c.close();
  }
  return totalBytes;
}

/// Whether every file of the channel's model exists (all non-empty).
Future<bool> isOnDeviceModelDownloaded(String channelId) async {
  final files = kOnDeviceModels[channelId];
  if (files == null) return false;
  final support = await getApplicationSupportDirectory();
  for (final f in files) {
    final file = File('${support.path}/models/${f.relativePath}');
    if (!await file.exists()) return false;
    if (await file.length() == 0) return false;
  }
  return true;
}

/// Deletes the channel's model files (the card's "remove model" action).
Future<void> deleteOnDeviceModel(String channelId) async {
  final files = kOnDeviceModels[channelId];
  if (files == null) return;
  final support = await getApplicationSupportDirectory();
  for (final f in files) {
    final file = File('${support.path}/models/${f.relativePath}');
    if (await file.exists()) await file.delete();
  }
}

/// Reads a downloaded model file's bytes (the sensevoice surface loads these).
Future<Uint8List> readOnDeviceModelFile(String channelId, String relativePath) async {
  final support = await getApplicationSupportDirectory();
  return File('${support.path}/models/$relativePath').readAsBytes();
}

/// The models directory path (`<app support>/models`), for surfaces that
/// build native config paths from it.
Future<String> modelsRoot() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}/models';
}
