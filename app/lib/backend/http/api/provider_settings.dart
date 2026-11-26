import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:omi/env/env.dart';

/// One provider card as the backend describes it (`/v1/provider/catalog`).
class ProviderChannel {
  const ProviderChannel({
    required this.id,
    required this.label,
    required this.capabilities,
    this.defaultBase = '',
    this.staticModels = const {},
    this.defaultVoice = '',
    this.requiresKey = true,
    this.discoverable = true,
  });

  final String id;
  final String label;
  final List<String> capabilities;
  final String defaultBase;
  final Map<String, List<String>> staticModels;
  final String defaultVoice;
  final bool requiresKey;
  final bool discoverable;

  factory ProviderChannel.fromJson(Map<String, dynamic> j) => ProviderChannel(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        capabilities: (j['capabilities'] as List?)?.whereType<String>().toList() ?? const [],
        defaultBase: j['defaultBase'] as String? ?? '',
        staticModels: _stringListMap(j['staticModels']),
        defaultVoice: j['defaultVoice'] as String? ?? '',
        requiresKey: j['requiresKey'] as bool? ?? true,
        discoverable: j['discoverable'] as bool? ?? true,
      );
}

/// A saved card on the backend (`/v1/provider/settings` accounts[]).
class ProviderAccount {
  const ProviderAccount({
    required this.id,
    this.baseUrl = '',
    this.selectedModels = const {},
    this.discoveredModels = const {},
    this.capabilities = const {},
    this.defaultVoice = '',
  });

  final String id;
  final String baseUrl;
  final Map<String, String> selectedModels;
  final Map<String, List<String>> discoveredModels;
  final Set<String> capabilities;
  final String defaultVoice;

  factory ProviderAccount.fromJson(Map<String, dynamic> j) => ProviderAccount(
        id: j['id'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        selectedModels: _stringMap(j['selectedModels']),
        discoveredModels: _stringListMap(j['discoveredModels']),
        capabilities: (j['capabilities'] as List?)?.whereType<String>().toSet() ?? const {},
        defaultVoice: j['defaultVoice'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'selectedModels': selectedModels,
        'discoveredModels': discoveredModels,
        'capabilities': capabilities.toList(),
        'defaultVoice': defaultVoice,
      };
}

/// One capability's route: primary channel plus ordered fallbacks.
class RouteChain {
  const RouteChain({this.primary = '', this.fallbacks = const []});

  final String primary;
  final List<String> fallbacks;

  factory RouteChain.fromJson(Object? j) {
    if (j is! Map) return const RouteChain();
    return RouteChain(
      primary: j['primary'] as String? ?? '',
      fallbacks: (j['fallbacks'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }

  Map<String, dynamic> toJson() => {'primary': primary, 'fallbacks': fallbacks};
}

/// Full provider settings document.
class ProviderSettings {
  const ProviderSettings({
    required this.version,
    required this.accounts,
    required this.routing,
  });

  final int version;
  final List<ProviderAccount> accounts;
  final Map<String, RouteChain> routing;

  factory ProviderSettings.fromJson(Map<String, dynamic> j) {
    final routing = <String, RouteChain>{};
    final raw = j['routing'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k is String) routing[k] = RouteChain.fromJson(v);
      });
    }
    return ProviderSettings(
      version: j['version'] as int? ?? 1,
      accounts: (j['accounts'] as List?)
              ?.whereType<Map>()
              .map((a) => ProviderAccount.fromJson(a.cast<String, dynamic>()))
              .toList() ??
          const [],
      routing: routing,
    );
  }

  ProviderAccount? account(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'accounts': accounts.map((a) => a.toJson()).toList(),
        'routing': {for (final e in routing.entries) e.key: e.value.toJson()},
      };
}

/// Catalog + settings + the "unified channel" active lists from the local
/// backend's provider surface.
class ProviderApi {
  const ProviderApi({this.send});

  /// Test seam: overrides the transport.
  final Future<http.Response> Function(String method, String path, String body)? send;

  Future<http.Response> _call(String method, String path, [String body = '']) {
    if (send != null) return send!(method, path, body);
    final uri = Uri.parse('${Env.apiBaseUrl}$path');
    return switch (method) {
      'GET' => http.get(uri),
      'PUT' => http.put(uri, headers: {'content-type': 'application/json'}, body: body),
      _ => http.post(uri, headers: {'content-type': 'application/json'}, body: body),
    };
  }

  Future<List<ProviderChannel>> getCatalog() async {
    final res = await _call('GET', 'v1/provider/catalog');
    if (res.statusCode != 200) throw ProviderApiException(res.statusCode);
    final row = jsonDecode(res.body) as Map<String, dynamic>;
    return (row['channels'] as List?)
            ?.whereType<Map>()
            .map((c) => ProviderChannel.fromJson(c.cast<String, dynamic>()))
            .toList() ??
        const [];
  }

  Future<ProviderSettings> getSettings() async {
    final res = await _call('GET', 'v1/provider/settings');
    if (res.statusCode != 200) throw ProviderApiException(res.statusCode);
    return ProviderSettings.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ProviderSettings> saveSettings(ProviderSettings settings) async {
    final res = await _call('PUT', 'v1/provider/settings', jsonEncode(settings.toJson()));
    if (res.statusCode != 200) throw ProviderApiException(res.statusCode);
    return ProviderSettings.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Capability name -> activated channel ids. Only these may join a route,
  /// which is what the unified picker lists.
  Future<Map<String, List<String>>> getActive() async {
    final res = await _call('GET', 'v1/provider/active');
    if (res.statusCode != 200) throw ProviderApiException(res.statusCode);
    final row = jsonDecode(res.body) as Map<String, dynamic>;
    return {
      for (final e in row.entries)
        if (e.value is List) e.key: (e.value as List).whereType<String>().toList(),
    };
  }

  Future<bool> setKey(String id, String key) async {
    final res = await _call('PUT', 'v1/provider/key', jsonEncode({'id': id, 'key': key}));
    if (res.statusCode != 200) throw ProviderApiException(res.statusCode);
    final row = jsonDecode(res.body) as Map<String, dynamic>;
    return row['activated'] as bool? ?? false;
  }

  /// Candidate models for a card capability, newest first.
  Future<List<String>> discover(String id, String capability) async {
    final res = await _call('POST', 'v1/provider/discover', jsonEncode({'id': id, 'capability': capability}));
    if (res.statusCode != 200) throw ProviderApiException(res.statusCode);
    final row = jsonDecode(res.body) as Map<String, dynamic>;
    return (row['candidates'] as List?)?.whereType<String>().toList() ?? const [];
  }
}

class ProviderApiException implements Exception {
  ProviderApiException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'ProviderApiException($statusCode)';
}

Map<String, String> _stringMap(Object? j) {
  if (j is! Map) return const {};
  final out = <String, String>{};
  j.forEach((k, v) {
    if (k is String && v is String) out[k] = v;
  });
  return out;
}

Map<String, List<String>> _stringListMap(Object? j) {
  if (j is! Map) return const {};
  final out = <String, List<String>>{};
  j.forEach((k, v) {
    if (k is String && v is List) out[k] = v.whereType<String>().toList();
  });
  return out;
}
