import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider_surfaces.dart';

const kDefaultLlmUpstream = 'http://127.0.0.1:4000/v1';

/// OpenAI-compatible chat client pointed at the local gateway (LiteLLM
/// `:4000/v1` in the harness; deepseek-flash is the model behind it).
/// Serves both desktop `/v2/chat/completions` (non-stream) and mobile
/// `/v2/messages` (SSE stream).
class LlmClient implements LlmSurface {
  LlmClient({
    http.Client? client,
    this.upstream = kDefaultLlmUpstream,
    this.apiKey,
    this.defaultModel = 'deepseek-flash',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String upstream;
  final String? apiKey;
  final String defaultModel;

  Map<String, String> _headers() => {
    'content-type': 'application/json',
    if (apiKey != null) 'authorization': 'Bearer $apiKey',
  };

  Uri get _uri => Uri.parse('$upstream/chat/completions');

  Map<String, dynamic> _body(
    String? model,
    List<Map<String, String>> messages,
    double? temperature, {
    required bool stream,
  }) => {'model': model ?? defaultModel, 'messages': messages, 'stream': stream, 'temperature': ?temperature};

  /// Non-streaming completion. Returns assistant text ('' when the provider
  /// returns no choices — the desktop tolerates that as empty_answer).
  @override
  Future<LlmReply> complete(List<Map<String, String>> messages, {String? model, double? temperature}) async {
    final res = await _client.post(
      _uri,
      headers: _headers(),
      body: jsonEncode(_body(model, messages, temperature, stream: false)),
    );
    if (res.statusCode != 200) {
      throw LlmException('upstream ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List? ?? const [];
    final content = choices.isEmpty ? '' : (((choices.first as Map)['message'] as Map?)?['content'] as String? ?? '');
    return LlmReply(content: content, model: decoded['model'] as String?);
  }

  /// Streaming completion yielding content deltas as they arrive.
  @override
  Stream<String> stream(List<Map<String, String>> messages, {String? model, double? temperature}) async* {
    final req = http.Request('POST', _uri)
      ..headers.addAll(_headers())
      ..body = jsonEncode(_body(model, messages, temperature, stream: true));
    final res = await _client.send(req);
    if (res.statusCode != 200) {
      throw LlmException('upstream ${res.statusCode}');
    }
    final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue; // tolerate provider keep-alives / partial frames
      }
      final delta = ((chunk['choices'] as List?)?.first as Map?)?['delta'] as Map?;
      final text = delta?['content'] as String?;
      if (text != null && text.isNotEmpty) yield text;
    }
  }

  void close() => _client.close();
}

class LlmReply {
  LlmReply({required this.content, this.model});
  final String content;
  final String? model;
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => 'LlmException: $message';
}
