/// Resolves provider cards + routes into concrete upstream clients.
///
/// Replaces the single-channel hardcodes this backend shipped with: instead of
/// one fixed LLM/STT/TTS upstream, each capability walks its route chain
/// (primary then fallbacks) and uses the first activated channel.
///
/// Protocol coverage is deliberately narrow — OpenAI-compatible chat, multipart
/// transcription, OpenAI `/v1/audio/speech`. Channel-specific protocols (Doubao
/// SAUC websocket, MiniMax `t2a_v2`) are not wired here yet; such a card falls
/// through to the next channel in the chain rather than sending a wrong body.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'db.dart';
import 'llm_client.dart';
import 'provider_catalog.dart';
import 'provider_settings.dart';
import 'stt_client.dart';
import 'provider_surfaces.dart';
import 'tts.dart';
import 'tts_client.dart';

/// A channel in the route chain cannot serve this capability with a protocol
/// this backend implements; the chain moves on to the next channel.
class ProviderUnsupported implements Exception {
  ProviderUnsupported(this.message);
  final String message;
  @override
  String toString() => 'ProviderUnsupported: $message';
}

/// Key storage for provider cards. Keys never enter the settings JSON.
class ProviderKeyStore {
  ProviderKeyStore(this._db);
  final LocalDb _db;

  static String _k(String id) => 'provider_key:$id';
  static String _m(String id) => 'provider_model:$id';

  String? key(String id) {
    final v = _db.getSetting(_k(id));
    return (v == null || v.isEmpty) ? null : v;
  }

  void setKey(String id, String? key) {
    if (key == null || key.trim().isEmpty) {
      _db.db.execute('DELETE FROM settings WHERE key = ?', [_k(id)]);
      return;
    }
    _db.setSetting(_k(id), key.trim());
  }

  /// On-device model state for `requiresModel` channels. Absent row = not
  /// downloaded = card inactive (nothing was ever fetched).
  Map<String, Object?>? modelState(String id) {
    final v = _db.getSetting(_m(id));
    if (v == null) return null;
    try {
      final parsed = jsonDecode(v);
      return parsed is Map<String, Object?> ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  /// Record the downloaded model for an on-device channel.
  void setModelState(String id, {required String model, required int sizeBytes}) {
    _db.setSetting(_m(id), jsonEncode({
      'downloaded': true,
      'model': model,
      'sizeBytes': sizeBytes,
    }));
  }

  void clearModelState(String id) {
    _db.db.execute('DELETE FROM settings WHERE key = ?', [_m(id)]);
  }

  bool modelDownloaded(String id) => modelState(id)?['downloaded'] == true;

  /// A channel is activated when it needs no key (local/edge) or has one,
  /// AND, for on-device model channels, the user has downloaded the model.
  bool activated(String id) {
    final d = descriptorOf(id);
    if (d == null) return false;
    if (d.requiresModel && !modelDownloaded(id)) return false;
    if (!d.requiresKey) return true;
    return key(id) != null;
  }
}

/// One resolved channel for one capability.
class ResolvedChannel {
  ResolvedChannel({
    required this.id,
    required this.base,
    this.endpoint,
    required this.model,
    this.key,
    this.voice = '',
  });

  final String id;
  final String base;
  final String? endpoint;
  final String model;
  final String? key;
  final String voice;
}

class ProviderRouter {
  /// [localStt] maps on-device card ids to in-process surfaces:
  /// `local-stt` (whisper fallback), `local-whisper`, `local-sensevoice`.
  /// An absent id (or an empty map, the standalone harness) keeps that card
  /// on its HTTP worker port.
  ProviderRouter(this._db, {Map<String, SttSurface>? localStt, this.localTts, this.localEmbed})
    : _keys = ProviderKeyStore(_db),
      localStt = localStt ?? const {},
      _settings = ProviderSettings.decode(_db.getSetting(_settingsKey));

  static const String _settingsKey = 'provider_settings';

  final LocalDb _db;
  final ProviderKeyStore _keys;

  /// Channel id -> in-process STT surface. STT needs per-card engines
  /// (whisper vs sensevoice); TTS is one engine, so it stays a single surface.
  final Map<String, SttSurface> localStt;

  /// In-process on-device TTS for the `local-tts` card. Null (the standalone
  /// harness) keeps the card on its HTTP worker port.
  final TtsSurface? localTts;

  /// In-process on-device embedding for the `local-embed` card (memory
  /// vector search). Null keeps the zero-vector stub replies.
  final EmbedSurface? localEmbed;
  ProviderSettings _settings;

  ProviderSettings get settings => _settings;
  ProviderKeyStore get keys => _keys;

  void reload() => _settings = ProviderSettings.decode(_db.getSetting(_settingsKey));

  /// Replace settings atomically and persist.
  void save(ProviderSettings next) {
    _db.setSetting(_settingsKey, next.encode());
    _settings = next;
  }

  /// Capabilities a card serves: catalog for built-ins, the card's own set for
  /// custom.
  Set<String> capabilitiesOf(String id) {
    final account = _settings.account(id);
    final d = descriptorOf(id);
    if (account == null || d == null) return const {};
    if (id == 'custom') return account.capabilities;
    return d.capabilities.map((c) => c.name).toSet();
  }

  bool supports(String id, ProviderCapability cap) => capabilitiesOf(id).contains(cap.name);

  /// Channel ids that can serve [cap] right now: card exists, supports the
  /// capability, and is activated. This is the list the "unified channel"
  /// picker shows.
  List<String> activatedFor(ProviderCapability cap) => [
    for (final a in _settings.accounts)
      if (supports(a.id, cap) && _keys.activated(a.id)) a.id,
  ];

  /// Resolve the attempt order for [cap]: primary, then fallbacks, filtered to
  /// usable channels.
  List<ResolvedChannel> resolve(ProviderCapability cap) {
    final out = <ResolvedChannel>[];
    for (final id in _settings.routing.chainFor(cap).chain) {
      if (!supports(id, cap) || !_keys.activated(id)) continue;
      final account = _settings.account(id);
      final d = descriptorOf(id);
      if (account == null || d == null) continue;
      final base = account.baseUrl.trim().isNotEmpty ? account.baseUrl.trim() : d.defaultBase;
      final override = account.endpointOverrides[cap.name]?.trim();
      out.add(
        ResolvedChannel(
          id: id,
          base: base,
          endpoint: (override != null && override.isNotEmpty) ? override : d.defaultEndpoints[cap.name],
          model: account.effectiveModel(cap),
          key: _keys.key(id),
          voice: account.defaultVoice.isNotEmpty ? account.defaultVoice : d.defaultVoice,
        ),
      );
    }
    return out;
  }

  LlmSurface llmSurface() => _RoutingLlm(this);
  SttSurface sttSurface() => _RoutingStt(this);
  TtsSurface ttsSurface() => _RoutingTts(this);
}

LlmClient _llmClientFor(ResolvedChannel c) {
  final upstream = c.endpoint?.trim().isNotEmpty == true ? _stripChat(c.endpoint!) : c.base;
  if (upstream.trim().isEmpty) {
    throw ProviderUnsupported('${c.id}: no LLM base/endpoint');
  }
  return LlmClient(
    upstream: upstream.trim().replaceAll(RegExp(r'/+$'), ''),
    apiKey: c.key,
    defaultModel: c.model.isEmpty ? 'deepseek-flash' : c.model,
  );
}

/// Accept either a base (`http://h:4000/v1`) or a full chat URL.
String _stripChat(String raw) => raw.replaceAll(RegExp(r'/chat/completions/*$'), '');

SttClient _sttClientFor(ResolvedChannel c) {
  final upstream = c.endpoint?.trim().isNotEmpty == true ? _stripTranscribe(c.endpoint!) : c.base;
  if (upstream.trim().isEmpty) {
    throw ProviderUnsupported('${c.id}: no STT base/endpoint');
  }
  return SttClient(upstream: upstream.trim().replaceAll(RegExp(r'/+$'), ''));
}

String _stripTranscribe(String raw) => raw.replaceAll(RegExp(r'/(v2/voice-message/|v1/stt/)?transcribe/*$'), '');

TtsClient _ttsClientFor(ResolvedChannel c) {
  final upstream = c.endpoint?.trim().isNotEmpty == true ? _stripSpeech(c.endpoint!) : c.base;
  if (upstream.trim().isEmpty) {
    throw ProviderUnsupported('${c.id}: no TTS base/endpoint');
  }
  return TtsClient(upstream: upstream.trim().replaceAll(RegExp(r'/+$'), ''));
}

String _stripSpeech(String raw) => raw.replaceAll(RegExp(r'/v1/audio/speech/*$'), '');

class _RoutingLlm implements LlmSurface {
  _RoutingLlm(this._router);
  final ProviderRouter _router;

  @override
  Future<LlmReply> complete(List<Map<String, String>> messages, {String? model, double? temperature}) async {
    Object? lastErr;
    for (final c in _router.resolve(ProviderCapability.llm)) {
      try {
        final client = _llmClientFor(c);
        try {
          return await client.complete(
            messages,
            model: model ?? (c.model.isEmpty ? null : c.model),
            temperature: temperature,
          );
        } finally {
          client.close();
        }
      } catch (e) {
        lastErr = e;
      }
    }
    throw LlmException('no usable LLM channel: $lastErr');
  }

  @override
  Stream<String> stream(List<Map<String, String>> messages, {String? model, double? temperature}) async* {
    Object? lastErr;
    for (final c in _router.resolve(ProviderCapability.llm)) {
      final client = _llmClientFor(c);
      try {
        await for (final delta in client.stream(
          messages,
          model: model ?? (c.model.isEmpty ? null : c.model),
          temperature: temperature,
        )) {
          yield delta;
        }
        client.close();
        return;
      } catch (e) {
        lastErr = e;
        client.close();
      }
    }
    throw LlmException('no usable LLM channel: $lastErr');
  }
}

class _RoutingStt implements SttSurface {
  _RoutingStt(this._router);
  final ProviderRouter _router;

  /// On-device cards serve in-process when the host injected a surface for
  /// that channel id. `local-whisper` / `local-sensevoice` have no HTTP base —
  /// without a surface the channel is simply unusable (skipped).
  SttSurface? _surfaceFor(ResolvedChannel c) => _router.localStt[c.id];

  @override
  Future<SttResult> transcribePcm(Uint8List pcm16, {int sampleRate = 16000, int channels = 1, String? language}) async {
    Object? lastErr;
    for (final c in _router.resolve(ProviderCapability.asr)) {
      try {
        final surface = _surfaceFor(c);
        if (surface != null) {
          return await surface.transcribePcm(pcm16, sampleRate: sampleRate, channels: channels, language: language);
        }
        final client = _sttClientFor(c);
        try {
          return await client.transcribePcm(pcm16, sampleRate: sampleRate, channels: channels, language: language);
        } finally {
          client.close();
        }
      } catch (e) {
        lastErr = e;
      }
    }
    throw SttException('no usable STT channel: $lastErr');
  }

  @override
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType) async {
    Object? lastErr;
    for (final c in _router.resolve(ProviderCapability.asr)) {
      try {
        final surface = _surfaceFor(c);
        if (surface != null) {
          return await surface.transcribeMultipart(body, contentType);
        }
        final client = _sttClientFor(c);
        try {
          return await client.transcribeMultipart(body, contentType);
        } finally {
          client.close();
        }
      } catch (e) {
        lastErr = e;
      }
    }
    throw SttException('no usable STT channel: $lastErr');
  }
}

class _RoutingTts implements TtsSurface {
  _RoutingTts(this._router);
  final ProviderRouter _router;

  /// The `local-tts` card serves in-process when the host injected an
  /// on-device surface.
  bool _onDevice(ResolvedChannel c) => c.id == 'local-tts' && _router.localTts != null;

  @override
  Future<Uint8List> synthesize(TtsRequest req) async {
    Object? lastErr;
    for (final c in _router.resolve(ProviderCapability.tts)) {
      try {
        if (_onDevice(c)) {
          // No voiceId: the on-device surface picks the system default voice.
          return await _router.localTts!.synthesize(TtsRequest(req.text));
        }
        final client = _ttsClientFor(c);
        try {
          final voice = req.voiceId ?? (c.voice.isEmpty ? null : c.voice);
          return await client.synthesize(TtsRequest(req.text, voiceId: voice));
        } finally {
          client.close();
        }
      } catch (e) {
        lastErr = e;
      }
    }
    throw TtsException('no usable TTS channel: $lastErr');
  }
}
