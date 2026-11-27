/// Provider card and route user settings.
///
/// Metadata only — keys never appear here. Keys live in the settings table
/// under `provider_key:<channelId>` and are resolved by the router. Persisted
/// as one JSON blob under `provider_settings` in the SQLite settings table.
/// Same two-level shape the XiaoWo app used: one card per channel with
/// `selectedModels[capability]`, plus a global route per capability.
library;

import 'dart:convert';

import 'provider_catalog.dart';

/// One channel card.
class ProviderAccount {
  ProviderAccount({
    required this.id,
    this.label = '',
    this.baseUrl = '',
    Map<String, String>? endpointOverrides,
    Map<String, String>? selectedModels,
    Map<String, List<String>>? discoveredModels,
    Set<String>? capabilities,
    this.defaultVoice = '',
  }) : endpointOverrides = Map.unmodifiable(endpointOverrides ?? const {}),
       selectedModels = Map.unmodifiable(selectedModels ?? const {}),
       discoveredModels = Map.unmodifiable(discoveredModels ?? const <String, List<String>>{}),
       capabilities = Set.unmodifiable(capabilities ?? const {});

  final String id;
  final String label;
  final String baseUrl;
  final Map<String, String> endpointOverrides;

  /// Capability name -> current model. Empty = the catalog's newest model.
  final Map<String, String> selectedModels;
  final Map<String, List<String>> discoveredModels;

  /// Only custom cards use this; built-in cards take capabilities from the
  /// catalog.
  final Set<String> capabilities;
  final String defaultVoice;

  ProviderAccount copyWith({
    String? label,
    String? baseUrl,
    Map<String, String>? endpointOverrides,
    Map<String, String>? selectedModels,
    Map<String, List<String>>? discoveredModels,
    Set<String>? capabilities,
    String? defaultVoice,
  }) => ProviderAccount(
    id: id,
    label: label ?? this.label,
    baseUrl: baseUrl ?? this.baseUrl,
    endpointOverrides: endpointOverrides ?? this.endpointOverrides,
    selectedModels: selectedModels ?? this.selectedModels,
    discoveredModels: discoveredModels ?? this.discoveredModels,
    capabilities: capabilities ?? this.capabilities,
    defaultVoice: defaultVoice ?? this.defaultVoice,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'baseUrl': baseUrl,
    'endpointOverrides': Map.of(endpointOverrides),
    'selectedModels': Map.of(selectedModels),
    'discoveredModels': {for (final e in discoveredModels.entries) e.key: List.of(e.value)},
    'capabilities': capabilities.toList()..sort(),
    'defaultVoice': defaultVoice,
  };

  factory ProviderAccount.fromJson(Object? json) {
    if (json is! Map) return ProviderAccount(id: '');
    final select = <String, String>{};
    final rawSel = json['selectedModels'];
    if (rawSel is Map) {
      rawSel.forEach((k, v) {
        if (k is String && v is String) select[k] = v;
      });
    }
    final discover = <String, List<String>>{};
    final rawDisc = json['discoveredModels'];
    if (rawDisc is Map) {
      rawDisc.forEach((k, v) {
        if (k is String && v is List) {
          discover[k] = v.whereType<String>().toList();
        }
      });
    }
    return ProviderAccount(
      id: json['id'] is String ? json['id'] as String : '',
      label: json['label'] is String ? json['label'] as String : '',
      baseUrl: json['baseUrl'] is String ? json['baseUrl'] as String : '',
      endpointOverrides: _stringMap(json['endpointOverrides']),
      selectedModels: select,
      discoveredModels: discover,
      capabilities: _stringSet(json['capabilities']),
      defaultVoice: json['defaultVoice'] is String ? json['defaultVoice'] as String : '',
    );
  }

  /// Candidate models for one capability: discovered + static, newest-first.
  /// The first entry is what the card shows as the default ("newest").
  List<String> candidates(ProviderCapability cap) {
    final d = descriptorOf(id);
    final discovered = discoveredModels[cap.name] ?? const <String>[];
    final staticList = d?.staticModels[cap.name] ?? const <String>[];
    final manual = selectedModels[cap.name] ?? '';
    final pool = <String>[...discovered, ...staticList, if (manual.isNotEmpty) manual];
    return sortModels(pool, staticOrder: staticList);
  }

  /// Effective model for a capability: explicit selection, else newest.
  String effectiveModel(ProviderCapability cap) {
    final manual = selectedModels[cap.name] ?? '';
    if (manual.isNotEmpty) return manual;
    final cands = candidates(cap);
    return cands.isEmpty ? '' : cands.first;
  }
}

/// One capability's route: primary channel plus fallbacks.
class RouteChain {
  RouteChain({this.primary = '', Iterable<String> fallbacks = const []})
    : fallbacks = List.unmodifiable(_clean(primary, fallbacks));

  final String primary;
  final List<String> fallbacks;

  static List<String> _clean(String primary, Iterable<String> raw) {
    final out = <String>[];
    for (final f in raw) {
      if (f != primary && !out.contains(f)) out.add(f);
    }
    return out;
  }

  /// Primary + fallbacks, in attempt order.
  List<String> get chain => [if (primary.isNotEmpty) primary, ...fallbacks];

  RouteChain copyWith({String? primary, List<String>? fallbacks}) =>
      RouteChain(primary: primary ?? this.primary, fallbacks: fallbacks ?? this.fallbacks);

  Map<String, Object?> toJson() => {'primary': primary, 'fallbacks': List.of(fallbacks)};

  factory RouteChain.fromJson(Object? json) {
    if (json is! Map) return RouteChain();
    final raw = json['fallbacks'];
    return RouteChain(
      primary: json['primary'] is String ? json['primary'] as String : '',
      fallbacks: raw is List ? raw.whereType<String>() : const <String>[],
    );
  }
}

/// Per-capability routing. The app edits this from the "unified channel"
/// section, which only lists activated channels.
class ProviderRouting {
  ProviderRouting({
    required this.asr,
    required this.tts,
    required this.realtime,
    required this.llm,
    this.vision,
    this.video,
    this.embed,
  });

  final RouteChain asr;
  final RouteChain tts;
  final RouteChain realtime;
  final RouteChain llm;

  /// Empty/null = follow the main LLM.
  final RouteChain? vision;

  /// Empty/null = not configured.
  final RouteChain? video;

  /// Embedding chain: empty until the local-embed card's model is installed.
  final RouteChain? embed;

  factory ProviderRouting.empty() =>
      ProviderRouting(asr: RouteChain(), tts: RouteChain(), realtime: RouteChain(), llm: RouteChain());

  /// Local defaults so a fresh install keeps the single-channel behaviour.
  /// LLM primary stays empty (no on-device LLM) with the domestic free-tier
  /// providers as fallbacks: a card without a key is skipped automatically,
  /// so the first key the user fills (modelscope / siliconflow / unisound /
  /// xfyun) becomes the working chat path.
  factory ProviderRouting.localDefaults() => ProviderRouting(
    asr: RouteChain(primary: 'local-stt', fallbacks: ['siliconflow', 'unisound']),
    tts: RouteChain(primary: 'local-tts', fallbacks: ['unisound']),
    realtime: RouteChain(),
    llm: RouteChain(fallbacks: ['modelscope', 'siliconflow', 'unisound', 'xfyun']),
    embed: RouteChain(primary: 'local-embed', fallbacks: ['siliconflow']),
  );

  RouteChain chainFor(ProviderCapability cap) => switch (cap) {
    ProviderCapability.asr => asr,
    ProviderCapability.tts => tts,
    ProviderCapability.realtime => realtime,
    ProviderCapability.llm => llm,
    ProviderCapability.vision => vision ?? llm,
    ProviderCapability.video => video ?? RouteChain(),
    ProviderCapability.embed => embed ?? RouteChain(),
  };

  ProviderRouting copyWith({
    RouteChain? asr,
    RouteChain? tts,
    RouteChain? realtime,
    RouteChain? llm,
    RouteChain? vision,
    bool clearVision = false,
    RouteChain? video,
    bool clearVideo = false,
    RouteChain? embed,
    bool clearEmbed = false,
  }) => ProviderRouting(
    asr: asr ?? this.asr,
    tts: tts ?? this.tts,
    realtime: realtime ?? this.realtime,
    llm: llm ?? this.llm,
    vision: clearVision ? null : (vision ?? this.vision),
    video: clearVideo ? null : (video ?? this.video),
    embed: clearEmbed ? null : (embed ?? this.embed),
  );

  Map<String, Object?> toJson() => {
    'asr': asr.toJson(),
    'tts': tts.toJson(),
    'realtime': realtime.toJson(),
    'llm': llm.toJson(),
    if (vision != null) 'vision': vision!.toJson(),
    if (video != null) 'video': video!.toJson(),
    if (embed != null) 'embed': embed!.toJson(),
  };

  factory ProviderRouting.fromJson(Object? json) {
    if (json is! Map) return ProviderRouting.localDefaults();
    return ProviderRouting(
      asr: RouteChain.fromJson(json['asr']),
      tts: RouteChain.fromJson(json['tts']),
      realtime: RouteChain.fromJson(json['realtime']),
      llm: RouteChain.fromJson(json['llm']),
      vision: json['vision'] == null ? null : RouteChain.fromJson(json['vision']),
      video: json['video'] == null ? null : RouteChain.fromJson(json['video']),
      embed: json['embed'] == null ? null : RouteChain.fromJson(json['embed']),
    );
  }
}

/// Top-level provider settings.
class ProviderSettings {
  ProviderSettings({required this.version, required List<ProviderAccount> accounts, required this.routing})
    : accounts = List.unmodifiable(accounts);

  static const int currentVersion = 1;

  final int version;
  final List<ProviderAccount> accounts;
  final ProviderRouting routing;

  factory ProviderSettings.empty() =>
      ProviderSettings(version: currentVersion, accounts: const [], routing: ProviderRouting.localDefaults());

  /// Fresh install: one card per key-free channel (the local trio + Edge),
  /// routes pointing at the local trio.
  factory ProviderSettings.defaults() => ProviderSettings(
    version: currentVersion,
    accounts: [
      for (final d in kProviderCatalog)
        if (!d.requiresKey) ProviderAccount(id: d.id),
    ],
    routing: ProviderRouting.localDefaults(),
  );

  ProviderAccount? account(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  ProviderSettings copyWith({List<ProviderAccount>? accounts, ProviderRouting? routing}) =>
      ProviderSettings(version: version, accounts: accounts ?? this.accounts, routing: routing ?? this.routing);

  /// Upsert a card by id, preserving list order (or appending).
  ProviderSettings withAccount(ProviderAccount account) {
    final next = <ProviderAccount>[];
    var replaced = false;
    for (final a in accounts) {
      if (a.id == account.id) {
        next.add(account);
        replaced = true;
      } else {
        next.add(a);
      }
    }
    if (!replaced) next.add(account);
    return copyWith(accounts: next);
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'accounts': accounts.map((a) => a.toJson()).toList(),
    'routing': routing.toJson(),
  };

  factory ProviderSettings.fromJson(Object? json) {
    if (json is! Map) return ProviderSettings.defaults();
    if (json['version'] is! int || json['version'] != currentVersion) {
      return ProviderSettings.defaults();
    }
    final accounts = <ProviderAccount>[];
    final raw = json['accounts'];
    if (raw is List) {
      for (final a in raw) {
        if (a is Map && a['id'] is String) {
          accounts.add(ProviderAccount.fromJson(a));
        }
      }
    }
    return ProviderSettings(
      version: currentVersion,
      accounts: accounts,
      routing: ProviderRouting.fromJson(json['routing']),
    );
  }

  String encode() => jsonEncode(toJson());

  static ProviderSettings decode(String? text) {
    if (text == null || text.trim().isEmpty) {
      return ProviderSettings.defaults();
    }
    try {
      return ProviderSettings.fromJson(jsonDecode(text));
    } catch (_) {
      return ProviderSettings.defaults();
    }
  }
}

Map<String, String> _stringMap(Object? json) {
  if (json is! Map) return const {};
  final out = <String, String>{};
  json.forEach((k, v) {
    if (k is String && v is String) out[k] = v;
  });
  return out;
}

Set<String> _stringSet(Object? json) {
  if (json is! List) return const {};
  return json.whereType<String>().toSet();
}
