import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_backend/embedded.dart';

import 'package:omi/local_backend/sensevoice_stt_surface.dart';
import 'package:omi/services/sockets/on_device_whisper_provider.dart';
import 'package:omi/utils/audio/wav_bytes.dart';

/// On-device inference surfaces the embedded backend routes the on-device
/// provider cards to. STT is per-card (whisper for `local-stt` /
/// `local-whisper`, sherpa-onnx for `local-sensevoice`); TTS runs through the
/// system speech engine (`flutter_tts`). None opens a socket.
class OnDeviceInferenceSurfaces {
  OnDeviceInferenceSurfaces._(this.sttByCard, this.tts);

  static Future<OnDeviceInferenceSurfaces> create() async {
    final support = await getApplicationSupportDirectory();
    final whisper = OnDeviceWhisperSttSurface(modelsDir: '${support.path}/models');
    return OnDeviceInferenceSurfaces._(
      {
        // The legacy local-stt card: whisper fallback (the FunASR worker is
        // absent on an embedded device, whisper.cpp is the on-device path).
        'local-stt': whisper,
        'local-whisper': whisper,
        'local-sensevoice': SenseVoiceSttSurface(),
      },
      OnDeviceTtsSurface(),
    );
  }

  /// Provider card id -> in-process STT surface.
  final Map<String, SttSurface> sttByCard;
  final OnDeviceTtsSurface tts;
}

/// `local-stt` card, served by on-device whisper.cpp.
class OnDeviceWhisperSttSurface implements SttSurface {
  OnDeviceWhisperSttSurface({required this.modelsDir});

  /// `<app support>/models` — same directory `FreemiumTranscriptionService`
  /// and the Transcription settings page download `ggml-*.bin` into.
  final String modelsDir;

  OnDeviceWhisperProvider? _provider;

  Future<OnDeviceWhisperProvider> _ensureProvider() async {
    final existing = _provider;
    if (existing != null) return existing;
    final modelPath = await findWhisperModel(modelsDir);
    if (modelPath == null) {
      throw SttException('on-device whisper model not downloaded '
          '(设备上未找到 Whisper 模型，请在 转录设置 里下载)');
    }
    // 'multi' lets whisper auto-detect the spoken language; the call-specific
    // language (if a route passes one) still narrows it.
    final provider = OnDeviceWhisperProvider(modelPath: modelPath, language: 'multi');
    _provider = provider;
    return provider;
  }

  Future<SttResult> _transcribe(Uint8List wav, String? language) async {
    final provider = await _ensureProvider();
    final result = await provider.transcribe(wav, language: language);
    if (result == null || result.isEmpty) {
      return SttResult(text: '', segments: const []);
    }
    return SttResult(
      text: result.rawText ?? '',
      segments: [
        for (final s in result.segments)
          SttSegment(text: s.text.trim(), start: s.start, end: s.end),
      ],
    );
  }

  @override
  Future<SttResult> transcribePcm(Uint8List pcm16,
      {int sampleRate = 16000, int channels = 1, String? language}) {
    final wav = WavBytes.fromPcm(pcm16, sampleRate: sampleRate, numChannels: channels).asBytes();
    return _transcribe(wav, language);
  }

  @override
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType) {
    // The body is a client-authored multipart form; pull the `file` part out
    // and feed its bytes to whisper (it normalizes WAV or raw PCM).
    final audio = _extractMultipartFile(body, contentType);
    return _transcribe(audio, null);
  }
}

/// Pulls the first file part's bytes out of a multipart/form body. A raw
/// (non-multipart) body is returned unchanged.
Uint8List _extractMultipartFile(Uint8List body, String contentType) {
  final boundary = RegExp('boundary="?([^";]+)"?').firstMatch(contentType)?.group(1);
  if (boundary == null) return body;
  final delim = Uint8List.fromList('--$boundary'.codeUnits);
  final first = _indexOfBytes(body, delim, 0);
  if (first < 0) return body;
  // Part headers end at the first blank line after the delimiter.
  final headersEnd = _indexOfBytes(body, Uint8List.fromList([13, 10, 13, 10]), first);
  int dataStart;
  if (headersEnd < 0) {
    // Malformed: no header block — treat everything after the delimiter line.
    dataStart = _indexOfBytes(body, Uint8List.fromList([13, 10]), first) + 2;
  } else {
    dataStart = headersEnd + 4;
  }
  // Data ends at the closing delimiter, minus the part's trailing CRLF.
  final close = _indexOfBytes(body, delim, dataStart);
  final dataEnd = close < 0 ? body.length : close - 2;
  return Uint8List.sublistView(body, dataStart, dataEnd > dataStart ? dataEnd : dataStart);
}

int _indexOfBytes(Uint8List haystack, Uint8List needle, int from) {
  if (needle.isEmpty) return from;
  for (var i = from; i <= haystack.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}

/// `local-tts` card, served by the system speech engine. Ignores the card's
/// voice ids (speaches/edge model names): the engine uses its default voice
/// for the set language.
class OnDeviceTtsSurface implements TtsSurface {
  OnDeviceTtsSurface({this.engineTimeout = const Duration(seconds: 10)});

  /// Engine calls that never resolve (no system TTS engine installed — its
  /// init fails with -1 and synth futures hang) are cut off at this bound.
  final Duration engineTimeout;

  FlutterTts? _tts;

  Future<T> _bounded<T>(Future<T> f) => f.timeout(
        engineTimeout,
        onTimeout: () => throw TtsException(
            'system tts engine unresponsive (no TTS engine installed?)'),
      );

  Future<FlutterTts> _ensureTts() async {
    final existing = _tts;
    if (existing != null) return existing;
    final engine = FlutterTts();
    // TextToSpeech constructs unbound and binds asynchronously; calls before
    // that log "not bound to TTS engine" and fail. Poll for readiness.
    final deadline = DateTime.now().add(engineTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _bounded(engine.isLanguageAvailable('zh-CN')) == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await _bounded(engine.setLanguage('zh-CN'));
    // Wait for synthesis to finish before synthesizeToFile's future resolves.
    await _bounded(engine.awaitSynthCompletion(true));
    _tts = engine;
    return engine;
  }

  @override
  Future<Uint8List> synthesize(TtsRequest req) async {
    final engine = await _ensureTts();
    final tmp = await getTemporaryDirectory();
    final out = File(
        '${tmp.path}/embedded_tts_${DateTime.now().millisecondsSinceEpoch}.wav');
    try {
      // isFullPath: Android otherwise resolves the name inside app storage.
      final code = await _bounded(engine.synthesizeToFile(req.text, out.path, true));
      if (code != 'success' && code != 1) {
        throw TtsException('system tts synthesis failed: $code');
      }
      final bytes = await out.readAsBytes();
      if (bytes.isEmpty) {
        throw TtsException('system tts wrote no audio');
      }
      return bytes;
    } finally {
      if (await out.exists()) await out.delete();
    }
  }
}

/// Newest installed whisper model, or null when none is downloaded.
/// Mirrors `FreemiumTranscriptionService`'s discovery: `ggml-<name>.bin` in
/// [modelsDir], smaller models preferred (they run on more phones).
Future<String?> findWhisperModel(String modelsDir) async {
  const priority = ['tiny', 'base', 'small', 'medium', 'large-v1', 'large-v2'];
  try {
    final files = await Directory(modelsDir).list().toList();
    for (final name in priority) {
      for (final f in files.whereType<File>()) {
        if (f.path.endsWith('ggml-$name.bin')) return f.path;
      }
    }
  } catch (_) {}
  return null;
}
