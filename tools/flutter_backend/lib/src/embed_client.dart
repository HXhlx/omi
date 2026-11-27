import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider_surfaces.dart';

/// OpenAI-compatible `/v1/embeddings` client: siliconflow (`BAAI/bge-m3`,
/// free tier), modelscope, any OpenAI-shaped gateway. Serves the router's
/// embed capability for cloud cards.
class EmbedClient implements EmbedSurface {
  EmbedClient({http.Client? client, required this.upstream, required this.apiKey, required this.model})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String upstream;
  final String? apiKey;
  final String model;

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final res = await _client.post(
      Uri.parse('$upstream/embeddings'),
      headers: {
        'content-type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({'model': model, 'input': texts}),
    );
    if (res.statusCode != 200) {
      throw EmbedException('upstream ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final data = decoded['data'] as List;
    // Sort by index: the API may return embeddings out of order.
    final rows = List<List<double>?>.filled(texts.length, null);
    for (final entry in data) {
      final e = entry as Map<String, dynamic>;
      final idx = (e['index'] as num?)?.toInt() ?? 0;
      if (idx < 0 || idx >= rows.length) continue;
      final values = (e['embedding'] as List?)?.whereType<num>().toList();
      if (values != null) {
        rows[idx] = [for (final v in values) v.toDouble()];
      }
    }
    if (rows.any((r) => r == null)) {
      throw EmbedException('upstream returned ${rows.whereType<List<double>>().length}/${texts.length} vectors');
    }
    return rows.whereType<List<double>>().toList();
  }

  void close() => _client.close();
}

class EmbedException implements Exception {
  EmbedException(this.message);
  final String message;
  @override
  String toString() => 'EmbedException: $message';
}
