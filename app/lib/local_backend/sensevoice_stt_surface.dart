import 'dart:typed_data';

import 'package:flutter_backend/embedded.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:omi/local_backend/on_device_models.dart';
import 'package:omi/utils/audio/wav_bytes.dart';

/// `local-sensevoice` card, served by sherpa-onnx running SenseVoice int8
/// in-process. Loads the model the on-demand downloader fetched; throws a
/// clear SttException naming the card when the model is absent (the card is
/// inactive then, so this only surfaces via a manual route).
class SenseVoiceSttSurface implements SttSurface {
  SenseVoiceSttSurface({this.sampleRate = 16000});

  final int sampleRate;

  sherpa.OfflineRecognizer? _recognizer;
  bool _bindingsReady = false;

  Future<sherpa.OfflineRecognizer> _ensureRecognizer() async {
    final existing = _recognizer;
    if (existing != null) return existing;
    if (!await isOnDeviceModelDownloaded('local-sensevoice')) {
      throw SttException('sensevoice model not downloaded '
          '(请在供应商卡片里下载 SenseVoice 模型)');
    }
    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }
    final root = await modelsRoot();
    final recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: '$root/sensevoice/model.int8.onnx',
            language: '',
            useInverseTextNormalization: true,
          ),
          tokens: '$root/sensevoice/tokens.txt',
        ),
      ),
    );
    _recognizer = recognizer;
    return recognizer;
  }

  Future<SttResult> _transcribe(Uint8List wavOrPcm, {bool isWav = false}) async {
    final recognizer = await _ensureRecognizer();
    final samples = _pcm16ToFloats(isWav ? _stripWavHeader(wavOrPcm) : wavOrPcm);
    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    recognizer.decode(stream);
    final text = recognizer.getResult(stream).text.trim();
    return SttResult(
      text: text,
      segments: text.isEmpty
          ? const []
          : [SttSegment(text: text, start: 0, end: samples.length / sampleRate)],
    );
  }

  @override
  Future<SttResult> transcribePcm(Uint8List pcm16,
      {int sampleRate = 16000, int channels = 1, String? language}) {
    // SenseVoice is multilingual (zh/en/ja/ko/yue); the language hint is
    // ignored — the model detects per utterance.
    return _transcribe(pcm16);
  }

  @override
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType) {
    // Multipart bodies carry a WAV file part; strip the container header.
    return _transcribe(body, isWav: true);
  }
}

/// PCM16 little-endian → Float32 [-1, 1].
Float32List _pcm16ToFloats(Uint8List pcm) {
  final count = pcm.length ~/ 2;
  final out = Float32List(count);
  final bd = ByteData.sublistView(pcm);
  for (var i = 0; i < count; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Strips a canonical 44-byte RIFF header when present.
Uint8List _stripWavHeader(Uint8List bytes) {
  if (bytes.length >= 44 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
      bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45) {
    return Uint8List.sublistView(bytes, 44);
  }
  return bytes;
}

/// Re-exported so the WAV helper stays the single wrapping implementation.
WavBytes wrapPcmAsWav(Uint8List pcm, {int sampleRate = 16000, int channels = 1}) =>
    WavBytes.fromPcm(pcm, sampleRate: sampleRate, numChannels: channels);
