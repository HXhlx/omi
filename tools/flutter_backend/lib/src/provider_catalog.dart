/// Provider card static catalog for the local backend.
///
/// Migrated from the XiaoWo app provider system. Describes "which channels
/// exist, what they can do, and their fallback model lists" — no user config,
/// no keys. The app's provider-settings page renders one card per entry; each
/// card lists every service (asr / tts / realtime / llm / vision / video) the
/// channel supports, newest-first.
///
/// The backend keeps this catalog authoritative so the app and the backend
/// agree on capabilities; the app fetches it from `/v1/provider/catalog`.
library;

/// Capability id. Wire JSON uses `.name`.
enum ProviderCapability { asr, tts, realtime, llm, vision, video, embed }

/// Static description of one channel.
class ProviderDescriptor {
  const ProviderDescriptor({
    required this.id,
    required this.label,
    required this.capabilities,
    this.defaultBase = '',
    this.defaultEndpoints = const {},
    this.staticModels = const {},
    this.defaultVoice = '',
    this.discoverable = true,
    this.requiresKey = true,
    this.requiresModel = false,
  });

  final String id;
  final String label;
  final Set<ProviderCapability> capabilities;

  /// Empty = no default; the card must fill it in.
  final String defaultBase;

  /// Capability name -> full default endpoint (channels whose base differs per
  /// service, e.g. Doubao ASR/TTS).
  final Map<String, String> defaultEndpoints;

  /// Capability name -> static model list, newest-first. Used as fallback when
  /// discovery fails or is unavailable.
  final Map<String, List<String>> staticModels;

  /// Default TTS voice; empty = a custom card must fill it.
  final String defaultVoice;

  /// Whether `/models` discovery applies.
  final bool discoverable;

  /// Local / key-free channels do not require a stored key.
  final bool requiresKey;

  /// On-device model channels activate only after the app reports the model
  /// downloaded via `PUT /v1/provider/model` — nothing is fetched unless the
  /// user picks the card.
  final bool requiresModel;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'capabilities': capabilities.map((c) => c.name).toList(),
    'defaultBase': defaultBase,
    'defaultEndpoints': defaultEndpoints,
    'staticModels': staticModels,
    'defaultVoice': defaultVoice,
    'discoverable': discoverable,
    'requiresKey': requiresKey,
    'requiresModel': requiresModel,
  };
}

ProviderCapability? capabilityFromName(String name) {
  for (final c in ProviderCapability.values) {
    if (c.name == name) return c;
  }
  return null;
}

/// Built-in channels. Local channels come first so a fresh install defaults to
/// them, matching the single-channel adapt this replaces.
const List<ProviderDescriptor> kProviderCatalog = <ProviderDescriptor>[
  ProviderDescriptor(
    id: 'local-stt',
    label: '本地 STT (FunASR)',
    capabilities: {ProviderCapability.asr},
    defaultBase: 'http://127.0.0.1:8200',
    staticModels: {
      'asr': ['funasr-paraformer-zh'],
    },
    discoverable: false,
    requiresKey: false,
  ),
  // On-device whisper: runs through the app's OnDeviceWhisperProvider
  // (whisper.cpp). The model is NOT bundled — it activates only after the app
  // reports it downloaded (`requiresModel`), so nothing is fetched unless the
  // user picks the card.
  ProviderDescriptor(
    id: 'local-whisper',
    label: '本地 ASR (Whisper)',
    capabilities: {ProviderCapability.asr},
    staticModels: {
      'asr': ['tiny', 'base', 'small'],
    },
    discoverable: false,
    requiresKey: false,
    requiresModel: true,
  ),
  // On-device SenseVoice via sherpa-onnx. Same on-demand model rule.
  ProviderDescriptor(
    id: 'local-sensevoice',
    label: '本地 ASR (SenseVoice)',
    capabilities: {ProviderCapability.asr},
    staticModels: {
      'asr': ['int8'],
    },
    discoverable: false,
    requiresKey: false,
    requiresModel: true,
  ),
  // No local-llm card: a generative LLM on a 2020-class phone (SD865,
  // 11.8GB RAM) is not usable (~5-8 tok/s even at 1.7B Q4). LLM/VLM stay
  // cloud-only (the slow model); a future on-device card would carry a small
  // decision/routing model, not a chat generator.
  ProviderDescriptor(
    id: 'local-tts',
    label: '本地 TTS (speaches)',
    capabilities: {ProviderCapability.tts},
    defaultBase: 'http://127.0.0.1:8300',
    staticModels: {
      'tts': ['speaches-ai/piper-zh_CN-huayan-medium'],
    },
    defaultVoice: 'speaches-ai/piper-zh_CN-huayan-medium',
    discoverable: false,
    requiresKey: false,
  ),
  ProviderDescriptor(
    id: 'edge',
    label: 'Edge TTS',
    capabilities: {ProviderCapability.tts},
    staticModels: {
      'tts': ['edge-tts'],
    },
    defaultVoice: 'zh-CN-XiaoxiaoNeural',
    discoverable: false,
    requiresKey: false,
  ),
  // On-device embedding for memory vector search. RequiresModel: the
  // weights download only when the user picks the card. Static list is the
  // selectable engine lineup — default is the quality/size sweet spot.
  ProviderDescriptor(
    id: 'local-embed',
    label: '本地嵌入 (bge)',
    capabilities: {ProviderCapability.embed},
    staticModels: {
      // [0] default: bge-base-zh-v1.5 int8, 102MB, dim 768, ~10ms/句 on
      // SD865. C-MTEB 2023 but still the zh quality/size sweet spot.
      'embed': [
        'bge-base-zh-v1.5',
        'bge-small-zh-v1.5',
        'qwen3-embedding-0.6b',
      ],
    },
    discoverable: false,
    requiresKey: false,
    requiresModel: true,
  ),
  ProviderDescriptor(
    id: 'minimax',
    label: 'MiniMax',
    capabilities: {ProviderCapability.asr, ProviderCapability.tts, ProviderCapability.llm, ProviderCapability.vision},
    defaultBase: 'https://api.minimax.chat/v1',
    staticModels: {
      'asr': ['asr-1.0'],
      'tts': ['speech-2.8-hd'],
      'llm': ['MiniMax-M3.1-Flash'],
      'vision': <String>[], // dynamic discovery only
    },
    defaultVoice: 'male-qn-qingse',
  ),
  ProviderDescriptor(
    id: 'qwen',
    label: '千问 Token Plan',
    capabilities: {
      ProviderCapability.asr,
      ProviderCapability.tts,
      ProviderCapability.realtime,
      ProviderCapability.video,
    },
    defaultBase: 'https://token-plan.maas.qianwenaiapi.com',
    defaultEndpoints: {
      'asr': 'https://token-plan.maas.qianwenaiapi.com/api/v1/services/aigc/multimodal-generation/generation',
      'realtime': 'wss://token-plan.maas.qianwenaiapi.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus',
    },
    staticModels: {
      'asr': ['qwen-audio-3.0-asr-flash'],
      'tts': ['qwen-audio-3.0-realtime-plus'],
      'realtime': ['qwen-audio-3.0-realtime-plus'],
      'video': ['qwen3.8-omni-flash', 'qwen4-max'],
    },
    defaultVoice: 'longanqian',
  ),
  ProviderDescriptor(
    id: 'unisound',
    label: '云知声',
    capabilities: {ProviderCapability.asr, ProviderCapability.tts},
    staticModels: {
      'asr': ['u2-asr'],
      'tts': ['u2-tts'],
    },
    defaultVoice: 'cn_male_chenyu',
  ),
  ProviderDescriptor(
    id: 'mimo',
    label: 'MiMo',
    capabilities: {ProviderCapability.tts, ProviderCapability.llm, ProviderCapability.vision},
    staticModels: {
      'tts': ['mimo-v2.5-tts'],
      'llm': <String>[],
      'vision': <String>[], // dynamic discovery only
    },
    defaultVoice: '白桦',
  ),
  ProviderDescriptor(
    id: 'doubao',
    label: '豆包 Agent Plan',
    capabilities: {ProviderCapability.asr, ProviderCapability.tts},
    defaultEndpoints: {
      'tts': 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
      'asr': 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    },
    staticModels: {
      'tts': ['seed-tts-2.0'],
      'asr': <String>[],
    },
    defaultVoice: 'zh_female_vv_uranus_bigtts',
    discoverable: false,
  ),
  ProviderDescriptor(
    id: 'siliconflow',
    label: '硅基流动',
    capabilities: {ProviderCapability.asr},
    defaultBase: 'https://api.siliconflow.cn/v1',
    staticModels: {
      'asr': [
        'XingChenAGI/XingChenASR-Diarize-V3.0',
        'XingChenAGI/XingChenASR-V3.2-Ultra',
        'XingChenAGI/XingChenGSR-V1.0',
      ],
    },
  ),
  ProviderDescriptor(
    id: 'custom',
    label: '自定义 OpenAI 兼容',
    capabilities: <ProviderCapability>{}, // chosen on the card
  ),
];

ProviderDescriptor? descriptorOf(String id) {
  for (final d in kProviderCatalog) {
    if (d.id == id) return d;
  }
  return null;
}

/// Local channels are key-free and always usable.
bool isLocalChannel(String id) => id.startsWith('local-');

const List<String> _llmExcluded = [
  'embedding',
  'rerank',
  'asr',
  'stt',
  'tts',
  'realtime',
  'live',
  'image',
  'video',
  'vision',
  'moderation',
];

bool _containsAny(String lower, List<String> words) {
  for (final w in words) {
    if (lower.contains(w)) return true;
  }
  return false;
}

/// Filter model ids by capability. Deduped, input order preserved.
List<String> filterModels(ProviderCapability cap, Iterable<String> ids) {
  final out = <String>[];
  for (final id in ids) {
    final lower = id.toLowerCase();
    final ok = switch (cap) {
      ProviderCapability.asr => _containsAny(lower, const ['asr', 'stt', 'transcribe', 'speech-to-text']),
      ProviderCapability.tts => _containsAny(lower, const ['tts', 'speech-synthesis', 'audio-tts']),
      ProviderCapability.realtime => _containsAny(lower, const ['realtime', 'live', 'omni']),
      ProviderCapability.llm => !_containsAny(lower, _llmExcluded),
      ProviderCapability.vision || ProviderCapability.video => true,
      ProviderCapability.embed => _containsAny(lower, const ['embed', 'bge', 'gte', 'e5']),
    };
    if (ok && !out.contains(id)) out.add(id);
  }
  return out;
}

final RegExp _previewRe = RegExp('preview|beta|alpha|experimental');
final RegExp _digitsRe = RegExp(r'\d+');

List<int> _versionParts(String id) => _digitsRe.allMatches(id).map((m) => int.parse(m.group(0)!)).toList();

int _compareVersion(List<int> a, List<int> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final av = i < a.length ? a[i] : 0;
    final bv = i < b.length ? b[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

/// Newest-first ordering: stable releases first, then version descending, then
/// static-list order, then name ascending. The card's default selection is
/// `sorted.first`, i.e. the newest stable model.
List<String> sortModels(Iterable<String> ids, {List<String> staticOrder = const <String>[]}) {
  final unique = ids.toSet().toList();
  final stable = unique.where((m) => !_previewRe.hasMatch(m.toLowerCase())).toList();
  final pool = stable.isNotEmpty ? stable : unique;
  final staticIndex = <String, int>{for (var i = 0; i < staticOrder.length; i++) staticOrder[i]: i};
  pool.sort((a, b) {
    final byVersion = _compareVersion(_versionParts(b), _versionParts(a));
    if (byVersion != 0) return byVersion;
    final ai = staticIndex[a] ?? staticOrder.length;
    final bi = staticIndex[b] ?? staticOrder.length;
    if (ai != bi) return ai.compareTo(bi);
    return a.compareTo(b);
  });
  return pool;
}

/// Model-discovery candidate URLs, in attempt order. Empty when the channel is
/// not discoverable or has no base.
List<String> modelUrlCandidates(String base, ProviderDescriptor d) {
  if (!d.discoverable || base.trim().isEmpty) return const [];
  final b = base.trim().replaceAll(RegExp(r'/+$'), '');
  final out = <String>[];
  void add(String u) {
    if (!out.contains(u)) out.add(u);
  }

  final hasV1 = b.contains('/v1');
  if (hasV1) add('$b/models');
  if (!hasV1) {
    add('$b/v1/models');
    add('$b/models');
  }
  return out;
}
