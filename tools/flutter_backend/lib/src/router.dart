import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'chat.dart';
import 'conversation.dart';
import 'db.dart';
import 'knowledge.dart';
import 'llm_client.dart';
import 'pipeline.dart';
import 'store.dart';
import 'stt_client.dart';
import 'tts.dart';
import 'tts_client.dart';

const _uuid = Uuid();

/// Single local user. Any Firebase-shaped Bearer maps here.
const kLocalUserId = 'local-dev-user';

/// Routes so far. Each new domain adds a branch; unknown paths fall
/// through to a JSON 404 that mimics FastAPI's `{"detail": "Not Found"}`.
class Api {
  Api(this._db, {TtsClient? tts, SttClient? stt, LlmClient? llm})
      : _conversations = ConversationStore(_db),
        _chat = ChatStore(_db),
        _knowledge = KnowledgeStore(_db) {
    _tts = tts ?? TtsClient();
    _stt = stt ?? SttClient();
    _llm = llm ?? LlmClient();
    _pipeline = ConversationPipeline(
        conversations: _conversations, knowledge: _knowledge, llm: _llm);
  }

  final LocalDb _db;
  final ConversationStore _conversations;
  final ChatStore _chat;
  final KnowledgeStore _knowledge;
  late final TtsClient _tts;
  late final SttClient _stt;
  late final LlmClient _llm;
  late final ConversationPipeline _pipeline;

  Handler get handler => (Request req) async {
        try {
          return await _dispatch(req);
        } catch (e) {
          return _json({'detail': 'Internal error: $e'}, status: 500);
        }
      };

  Future<Response> _dispatch(Request req) async {
    final path = req.url.path;
    final method = req.method;

    // ---- health ----
    if (path == 'health' || path == 'ready') {
      return _json({'status': 'ok', 'stage': 'offline', 'uid': kLocalUserId});
    }
    if (path == 'v1/health') return _json({'status': 'ok'});
    if (path == 'metrics') {
      return Response.ok('# flutter_backend\n',
          headers: {'content-type': 'text/plain; version=0.0.4'});
    }
    if (path == '_internal/boot') {
      return _json({'booted': _db.getSetting('booted'), 'uid': kLocalUserId});
    }

    // ---- stt ----
    if (path == 'v2/voice-message/transcribe' && method == 'POST') {
      return _transcribe(req);
    }
    if (path == 'v1/stt/transcribe' && method == 'POST') {
      return _transcribe(req);
    }

    // ---- tts ----
    if (path == 'v1/tts/voices' && method == 'GET') {
      return _json({
        'voices': kTtsVoices,
        'default_voice_id': kDefaultAssistantVoice,
      });
    }
    if (path == 'v1/users/voice') {
      if (method == 'GET') {
        return _json({'voice_id': _userVoice()});
      }
      if (method == 'PATCH') {
        final body = await _body(req);
        final vid = body['voice_id'] as String?;
        if (vid != null) _db.setSetting('assistant_voice', vid);
        return _json({'voice_id': _userVoice()});
      }
    }
    if ((path == 'v2/tts/synthesize' || path == 'v1/tts/synthesize') &&
        method == 'POST') {
      final reqBody = await _body(req);
      final text = (reqBody['text'] as String? ?? '').trim();
      if (text.isEmpty) {
        return _json({'detail': 'text must not be empty'}, status: 400);
      }
      if (text.length > 5000) {
        return _json(
            {'detail': 'text exceeds maximum length of 5000 characters'},
            status: 400);
      }
      final voiceId = reqBody['voice_id'] as String? ?? _userVoice();
      try {
        final mp3 = await _tts.synthesize(
            TtsRequest(text, voiceId: voiceId));
        return Response.ok(mp3, headers: {'content-type': 'audio/mpeg'});
      } on TtsException catch (e) {
        return _json({'detail': 'tts unavailable: ${e.message}'}, status: 503);
      }
    }

    // ---- memories ----
    if (path == 'v3/memories') {
      final q = req.url.queryParameters;
      if (method == 'GET') {
        final list = _knowledge.listMemories(
            limit: int.tryParse(q['limit'] ?? '') ?? 50,
            offset: int.tryParse(q['offset'] ?? '') ?? 0);
        return _json(list.map((m) => m.toWire()).toList());
      }
      if (method == 'POST') {
        final body = await _body(req);
        final m = Memory(
          id: _uuid.v4(),
          content: (body['content'] as String? ?? '').trim(),
          category: body['category'] as String? ?? 'interesting',
          createdAt: DateTime.now(),
        );
        if (m.content.isEmpty) {
          return _json({'detail': 'content must not be empty'}, status: 400);
        }
        _knowledge.upsertMemory(m);
        return _json(m.toWire());
      }
      if (method == 'DELETE') {
        _knowledge.clearMemories();
        return _json({'status': 'ok'});
      }
    }
    if (path == 'v3/memories/batch' && method == 'POST') {
      final body = await _body(req);
      final items = (body['memories'] as List? ?? body as List? ?? const []);
      var n = 0;
      for (final raw in items) {
        final map = raw as Map;
        final content = (map['content'] as String? ?? '').trim();
        if (content.isEmpty) continue;
        _knowledge.upsertMemory(Memory(
            id: _uuid.v4(), content: content, createdAt: DateTime.now()));
        n++;
      }
      return _json({'created': n});
    }
    final memId = _match(path, 'v3/memories/');
    if (memId != null && !memId.contains('/')) {
      if (method == 'PATCH') {
        final body = await _body(req);
        final existing = _knowledge.getMemory(memId);
        if (existing == null) return _json({'detail': 'Not Found'}, status: 404);
        final m = Memory(
          id: existing.id,
          content: body['content'] as String? ?? existing.content,
          category: body['category'] as String? ?? existing.category,
          createdAt: existing.createdAt,
        );
        _knowledge.upsertMemory(m);
        return _json(m.toWire());
      }
      if (method == 'DELETE') {
        _knowledge.deleteMemory(memId);
        return _json({'status': 'ok'});
      }
    }
    if (path == 'memory/search' && method == 'GET') {
      final query = req.url.queryParameters['query'] ?? '';
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 10;
      if (query.isEmpty) return _json({'items': <Object>[]});
      final hits = _knowledge.searchMemories(query, limit: limit);
      return _json({
        'items': hits.map((m) => m.toWire()).toList(),
        'query': query,
      });
    }
    if (path == 'memory/vector/search' && method == 'POST') {
      final body = await _body(req);
      final query = (body['query'] as String? ?? '').trim();
      if (query.isEmpty) return _json({'items': <Object>[]});
      final hits = _knowledge.searchMemories(
          query, limit: int.tryParse('${body['limit'] ?? 10}') ?? 10);
      return _json({'items': hits.map((m) => m.toWire()).toList()});
    }

    // ---- action items ----
    if (path == 'v1/action-items') {
      final q = req.url.queryParameters;
      if (method == 'GET') {
        final list = _knowledge.listActionItems(
            limit: int.tryParse(q['limit'] ?? '') ?? 50,
            offset: int.tryParse(q['offset'] ?? '') ?? 0);
        return _json({
          'action_items': list.map((a) => a.toWire()).toList(),
          'has_more': false,
          'truncated': false,
        });
      }
      if (method == 'POST') {
        final body = await _body(req);
        final desc =
            (body['description'] as String? ?? body['text'] as String? ?? '').trim();
        if (desc.isEmpty) {
          return _json({'detail': 'description must not be empty'}, status: 400);
        }
        final a = ActionItem(
          id: _uuid.v4(),
          description: desc,
          createdAt: DateTime.now(),
          conversationId: body['conversation_id'] as String?,
          source: body['source'] as String?,
        );
        _knowledge.upsertActionItem(a);
        return _json(a.toWire());
      }
    }
    final aiId = _match(path, 'v1/action-items/');
    if (aiId != null && !aiId.contains('/')) {
      final existing = _knowledge.getActionItem(aiId);
      if (method == 'GET') {
        return existing == null
            ? _json({'detail': 'Not Found'}, status: 404)
            : _json(existing.toWire());
      }
      if (method == 'PATCH') {
        if (existing == null) return _json({'detail': 'Not Found'}, status: 404);
        final body = await _body(req);
        final a = ActionItem(
          id: existing.id,
          description: body['description'] as String? ?? existing.description,
          completed: body['completed'] as bool? ?? existing.completed,
          createdAt: existing.createdAt,
          completedAt: (body['completed'] as bool? ?? existing.completed)
              ? (existing.completedAt ?? DateTime.now())
              : null,
          conversationId: existing.conversationId,
          dueAt: existing.dueAt,
        );
        _knowledge.upsertActionItem(a);
        return _json(a.toWire());
      }
      if (method == 'DELETE') {
        _knowledge.deleteActionItem(aiId);
        return Response(204);
      }
    }

    // ---- chat: desktop completions ----
    if (path == 'v2/chat/completions' && method == 'POST') {
      final body = await _body(req);
      final messages = ((body['messages'] as List?) ?? const [])
          .map((e) => _roleContent(e as Map))
          .toList();
      final stream = body['stream'] == true;
      try {
        if (stream) {
          final chunks = _llm.stream(messages, model: body['model'] as String?);
          return Response.ok(
            chunks.map(_sseDataChunk),
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }
        final reply =
            await _llm.complete(messages, model: body['model'] as String?);
        return _json({
          'id': 'chatcmpl-${_uuid.v4()}',
          'object': 'chat.completion',
          'model': reply.model ?? body['model'] ?? 'deepseek-flash',
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': reply.content},
              'finish_reason': 'stop',
            }
          ],
        });
      } on LlmException catch (e) {
        return _json({'error': {'message': e.message}}, status: 502);
      }
    }

    // ---- chat: mobile v2/messages (SSE) ----
    if (path == 'v2/messages') {
      final q = req.url.queryParameters;
      if (method == 'GET') {
        final list = _chat.messages(
            chatSessionId: q['chat_session_id'],
            limit: int.tryParse(q['limit'] ?? '') ?? 50,
            offset: int.tryParse(q['offset'] ?? '') ?? 0);
        return _json(list.map((m) => m.toWire()).toList());
      }
      if (method == 'DELETE') {
        _chat.clearMessages(chatSessionId: q['chat_session_id']);
        return Response(204);
      }
      if (method == 'POST') {
        return _sendChatMessage(req);
      }
    }

    // ---- chat sessions ----
    if (path == 'v2/chat-sessions') {
      final q = req.url.queryParameters;
      if (method == 'GET') {
        final list = _chat.listSessions(
            limit: int.tryParse(q['limit'] ?? '') ?? 50,
            offset: int.tryParse(q['offset'] ?? '') ?? 0);
        return _json(list.map((s) => s.toWire()).toList());
      }
      if (method == 'POST') {
        final body = await _body(req);
        final s = ChatSession(
          id: _uuid.v4(),
          createdAt: DateTime.now(),
          title: body['title'] as String?,
          appId: body['app_id'] as String?,
        );
        _chat.upsertSession(s);
        return _json(s.toWire());
      }
    }
    final sessId = _match(path, 'v2/chat-sessions/');
    if (sessId != null && !sessId.contains('/')) {
      if (method == 'GET') {
        final s = _chat.getSession(sessId);
        return s == null
            ? _json({'detail': 'Not Found'}, status: 404)
            : _json(s.toWire());
      }
      if (method == 'PATCH') {
        final body = await _body(req);
        final s = _chat.getSession(sessId);
        if (s == null) return _json({'detail': 'Not Found'}, status: 404);
        final updated = ChatSession(
          id: s.id,
          createdAt: s.createdAt,
          title: body['title'] as String? ?? s.title,
          appId: s.appId,
          starred: body['starred'] as bool? ?? s.starred,
          preview: s.preview,
        );
        _chat.upsertSession(updated);
        return _json(updated.toWire());
      }
      if (method == 'DELETE') {
        _chat.deleteSession(sessId);
        return Response(204);
      }
    }

    // ---- conversations ----
    if (path == 'v1/conversations' && method == 'GET') {
      final q = req.url.queryParameters;
      final limit = int.tryParse(q['limit'] ?? '') ?? 50;
      final offset = int.tryParse(q['offset'] ?? '') ?? 0;
      final list = _conversations.list(limit: limit, offset: offset);
      return _json(list.map((c) => c.toJson()).toList());
    }
    if (path == 'v1/conversations/count' && method == 'GET') {
      return _json({'count': _conversations.count()});
    }
    if (path == 'v1/conversations/from-segments' && method == 'POST') {
      final body = await _body(req);
      final segs = (body['transcript_segments'] as List? ?? body['segments'] as List? ?? [])
          .map((e) => TranscriptSegment.fromJson(e as Map<String, dynamic>))
          .toList();
      final now = DateTime.now();
      final c = Conversation(
        id: _uuid.v4(),
        startedAt: now,
        finishedAt: now,
        status: 'completed',
        source: body['source'] as String? ?? 'desktop',
        language: body['language'] as String? ?? 'zh',
        title: body['title'] as String?,
        transcript: segs,
      );
      _conversations.upsert(c);
      _conversations.replaceSegments(c.id, segs);
      return _json({'id': c.id, 'status': 'completed', 'discarded': false});
    }

    final convId = _match(path, 'v1/conversations/');
    if (convId != null) {
      // sub-resources: {id}/<tail>
      final slash = convId.indexOf('/');
      final id = slash < 0 ? convId : convId.substring(0, slash);
      final tail = slash < 0 ? '' : convId.substring(slash + 1);

      if (tail.isEmpty) {
        if (method == 'GET') {
          final c = _conversations.get(id);
          return c == null
              ? _json({'detail': 'Conversation not found'}, status: 404)
              : _json(c.toJson());
        }
        if (method == 'DELETE') {
          final cascade = req.url.queryParameters['cascade'] == 'true';
          _conversations.delete(id, cascade: cascade);
          return Response(204);
        }
      }
      if (tail == 'finalize' && method == 'POST') {
        final c = _conversations.get(id);
        if (c == null) return _json({'detail': 'Conversation not found'}, status: 404);
        final result = await _pipeline.process(id);
        return _json({
          ..._conversations.toWire(id),
          'pipeline': {
            'processed': result.processed,
            'memories': result.memories,
            'action_items': result.actionItems,
          },
        });
      }
      if (tail == 'reprocess' && method == 'POST') {
        final result = await _pipeline.process(id);
        if (!result.processed) {
          return _json({'detail': 'Conversation not found'}, status: 404);
        }
        return _json({
          'status': 'ok',
          'memories': result.memories,
          'action_items': result.actionItems,
        });
      }
      if (tail == 'title' && method == 'PATCH') {
        final body = await _body(req);
        final title = body['title'] as String?;
        final c = _conversations.get(id);
        if (c == null) return _json({'detail': 'Conversation not found'}, status: 404);
        _conversations.upsert(Conversation(
          id: c.id,
          startedAt: c.startedAt,
          finishedAt: c.finishedAt,
          status: c.status,
          source: c.source,
          language: c.language,
          title: title,
          visibility: c.visibility,
          discarded: c.discarded,
        ));
        return _json({'status': 'ok', 'title': title});
      }
      if (tail == 'visibility' && method == 'PATCH') {
        final body = await _body(req);
        return _json({'status': 'ok', 'visibility': body['visibility']});
      }
      if (tail == 'starred' && method == 'PATCH') {
        final body = await _body(req);
        return _json({'status': 'ok', 'starred': body['starred'] ?? false});
      }
    }

    return _json({'detail': 'Not Found', 'path': path}, status: 404);
  }

  static String? _match(String path, String prefix) =>
      path.startsWith(prefix) ? path.substring(prefix.length) : null;

  String _userVoice() => _db.getSetting('assistant_voice') ?? kDefaultAssistantVoice;

  /// Handles both client shapes the Omi backend accepts:
  /// - `application/octet-stream` raw PCM (desktop PTT), query `sample_rate`,
  ///   `channels`, `language`;
  /// - `multipart/form-data` with a `file` part (mobile), forwarded as-is.
  Future<Response> _transcribe(Request req) async {
    final contentType = req.headers['content-type'] ?? '';
    final bytes = await _readAll(req);
    if (bytes.isEmpty) {
      return _json({'detail': 'No audio data provided'}, status: 400);
    }
    try {
      SttResult result;
      if (contentType.contains('application/octet-stream')) {
        final q = req.url.queryParameters;
        result = await _stt.transcribePcm(
          bytes,
          sampleRate: int.tryParse(q['sample_rate'] ?? '') ?? 16000,
          channels: int.tryParse(q['channels'] ?? '') ?? 1,
          language: q['language'],
        );
      } else {
        result = await _stt.transcribeMultipart(bytes, contentType);
      }
      return _json({
        'transcript': result.text,
        'language': result.language,
        'segments': result.segments.map((s) => s.toJson()).toList(),
      });
    } on SttException catch (e) {
      return _json({'detail': 'stt unavailable: ${e.message}'}, status: 503);
    }
  }

  static Future<Uint8List> _readAll(Request req) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Persists the user turn, streams the LLM answer as Omi SSE frames
  /// (`data: <delta>`, then `message:` / `done:` with the full wire message),
  /// and stores the assistant turn.
  Future<Response> _sendChatMessage(Request req) async {
    final q = req.url.queryParameters;
    final sessionId = q['chat_session_id'];
    final data = await _body(req);
    final text = (data['text'] as String? ?? '').trim();
    if (text.isEmpty) return _json({'detail': 'text must not be empty'}, status: 400);

    final messageId = _uuid.v4();
    _chat.insertMessage(ChatMessage(
        id: messageId, role: 'user', text: text, createdAt: DateTime.now(),
        chatSessionId: sessionId));

    final messages = [
      {'role': 'system', 'content': _systemPrompt()},
      ..._chat.contextMessages(chatSessionId: sessionId),
    ];

    late StringBuffer full;
    Stream<String> emit() async* {
      full = StringBuffer();
      try {
        await for (final delta in _llm.stream(messages)) {
          full.write(delta);
          yield _sseLine('data: ', delta.replaceAll('\n', '__CRLF__'));
        }
      } on LlmException catch (e) {
        yield _sseLine('error: ', e.message);
        return;
      }
      final aiText = full.toString();
      final aiMessage = ChatMessage(
          id: _uuid.v4(), role: 'ai', text: aiText, createdAt: DateTime.now(),
          chatSessionId: sessionId);
      _chat.insertMessage(aiMessage);
      final wire = _jsonEncode(aiMessage.toWire());
      yield _sseLine('message: ', base64Encode(utf8.encode(wire)));
      yield _sseLine('done: ', base64Encode(utf8.encode(wire)));
    }

    return Response.ok(
      emit().map((line) => utf8.encode(line)),
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  }

  static Map<String, String> _roleContent(Map e) => {
        'role': e['role'] as String? ?? 'user',
        'content': (e['content'] ?? '').toString(),
      };

  static String _systemPrompt() =>
      '你是「小蜗」，一位面向无障碍场景的随身对话与记忆助手。回答简洁、友好，'
      '在需要时主动给出可执行的建议。';

  static Stream<String> _sseDataChunk(String delta) =>
      Stream.value(_sseLine('data: ', jsonEncode({
            'id': 'chatcmpl-local',
            'object': 'chat.completion.chunk',
            'choices': [
              {
                'index': 0,
                'delta': {'content': delta},
                'finish_reason': null,
              }
            ],
          })));

  static String _sseLine(String prefix, String payload) => '$prefix$payload\n\n';

  static String _jsonEncode(Object o) => jsonEncode(o);

  Future<Map<String, dynamic>> _body(Request req) async {
    final raw = await req.readAsString();
    if (raw.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}

Response _json(Object? data, {int status = 200}) => Response(
      status,
      body: jsonEncode(data),
      headers: {'content-type': 'application/json'},
    );