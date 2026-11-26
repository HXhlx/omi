import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

import 'chat.dart';
import 'conversation.dart';
import 'db.dart';
import 'extra_routes.dart';
import 'knowledge.dart';
import 'llm_client.dart';
import 'pipeline.dart';
import 'store.dart';
import 'stt_client.dart';
import 'tts.dart';
import 'tts_client.dart';
import 'user_store.dart';

const _uuid = Uuid();

/// First-party app catalog served to both clients in the local build. The
/// marketplace is offline, so apps comes from this small seeded list (matching
/// Omi category shapes) instead of a store network call.
const List<Map<String, dynamic>> _localApps = [
  {
    'id': 'meeting_summarizer',
    'name': '会议纪要',
    'category': 'productivity',
    'author': '小蜗',
    'description': '自动生成会议纪要、行动项与待办。',
    'image': '',
    'capabilities': ['conversation_processing'],
    'enabled': true,
    'approved': true,
    'official': true,
    'installs': 0,
  },
  {
    'id': 'persona-小蜗管家',
    'name': '小蜗管家',
    'category': 'persona',
    'author': '小蜗',
    'description': '贴在身边的管家：日程提醒、待办与家居控制入口。',
    'image': '',
    'capabilities': ['persona'],
    'enabled': true,
    'approved': true,
    'official': true,
    'installs': 0,
  },
];

/// Single local user. Any Firebase-shaped Bearer maps here.
const kLocalUserId = 'local-dev-user';

/// Routes so far. Each new domain adds a branch; unknown paths fall
/// through to a JSON 404 that mimics FastAPI's `{"detail": "Not Found"}`.
class Api {
  Api(this._db, {TtsClient? tts, SttClient? stt, LlmClient? llm})
      : _conversations = ConversationStore(_db),
        _chat = ChatStore(_db),
        _knowledge = KnowledgeStore(_db),
        _users = UserStore(_db) {
    _tts = tts ?? TtsClient();
    _stt = stt ?? SttClient();
    _llm = llm ?? LlmClient();
    _pipeline = ConversationPipeline(
        conversations: _conversations, knowledge: _knowledge, llm: _llm);
    _extra = ExtraRoutes(
      conversations: _conversations,
      knowledge: _knowledge,
      users: _users,
      llm: _llm,
    );
  }

  final LocalDb _db;
  final ConversationStore _conversations;
  final ChatStore _chat;
  final KnowledgeStore _knowledge;
  final UserStore _users;
  late final TtsClient _tts;
  late final SttClient _stt;
  late final LlmClient _llm;
  late final ConversationPipeline _pipeline;
  late final ExtraRoutes _extra;

  Handler get handler => (Request req) async {
        final path = req.url.path;
        // ---- live transcription websocket: /v4/listen (+ web alias) ----
        if (path == 'v4/listen' || path == 'v4/web/listen') {
          return _listenSocket(req);
        }
        if (path == 'v2/voice-message/transcribe-stream') {
          return _transcribeStreamSocket(req);
        }
        try {
          final res = await _dispatch(req);
          if (res.statusCode == 404) {
            // Param routes that named a static sub-resource (ids, canonical,
            // live, reorder, …) fall here; the long-tail table claims them.
            final extra = await _extra.handle(req, () => _body(req));
            if (extra != null) return extra;
          }
          return res;
        } catch (e) {
          return _json({'detail': 'Internal error: $e'}, status: 500);
        }
      };

  /// `/v4/listen`: client streams PCM16/other audio frames; the server batches
  /// them and transcribes through the local worker, emitting Omi's segment
  /// array frames (`[{text,start,end,speaker,is_user}]`). Finalization happens
  /// when the client sends `{'type':'finalization_reason'...}` or closes.
  Future<Response> _listenSocket(Request req) async {
    final q = req.url.queryParameters;
    final sampleRate = int.tryParse(q['sample_rate'] ?? '') ?? 16000;
    final language = q['language'];
    final handler = webSocketHandler((WebSocketChannel channel, _) {
      final pcm = BytesBuilder(copy: false);
      var conversationId = _uuid.v4();
      var lastStart = 0.0;

      Future<void> flush() async {
        if (pcm.length < sampleRate * 2 * 0.5) return; // <0.5s: nothing useful
        final bytes = pcm.takeBytes();
        try {
          final result = await _stt.transcribePcm(bytes,
              sampleRate: sampleRate, language: language);
          final segs = <Map<String, dynamic>>[];
          for (final s in result.segments) {
            segs.add({
              'text': s.text,
              'start': lastStart + s.start,
              'end': lastStart + s.end,
              'speaker': 'SPEAKER_00',
              'is_user': true,
            });
          }
          if (segs.isNotEmpty) {
            lastStart = segs.last['end'] as double;
            channel.sink.add(jsonEncode(segs));
          }
        } on SttException {
          // worker unavailable: keep the collector alive, no frames this batch.
        }
      }

      channel.stream.listen((Object? frame) async {
        if (frame is List<int>) {
          pcm.add(frame);
          if (pcm.length >= sampleRate * 2 * 6) {
            await flush(); // bounded batch (≤6s) to keep latency low
          }
          return;
        }
        if (frame is String) {
          Map<String, dynamic>? msg;
          try {
            msg = jsonDecode(frame) as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          final type = msg['type']?.toString();
          if (type == 'stop' ||
              type == 'finalization_reason' ||
              (msg['finalization_reason'] != null)) {
            await flush();
            channel.sink.add(jsonEncode({
              'type': 'conversation_processing_completed',
              'conversation_id': conversationId,
            }));
          }
          if (msg['client_conversation_id'] != null) {
            conversationId = msg['client_conversation_id'] as String;
          }
        }
      }, onDone: () async {
        await flush();
        await channel.sink.close();
      });
    });
    return handler(req);
  }

  /// `/v2/voice-message/transcribe-stream`: one-shot PTT stream; hand back the
  /// transcript as segment arrays after each bounded batch (no conversation).
  Future<Response> _transcribeStreamSocket(Request req) async {
    final q = req.url.queryParameters;
    final sampleRate = int.tryParse(q['sample_rate'] ?? '') ?? 16000;
    final handler = webSocketHandler((WebSocketChannel channel, _) {
      final pcm = BytesBuilder(copy: false);
      channel.stream.listen((Object? frame) async {
        if (frame is! List<int>) return;
        pcm.add(frame);
        if (pcm.length >= sampleRate * 2 * 4) {
          final bytes = pcm.takeBytes();
          try {
            final result = await _stt.transcribePcm(bytes,
                sampleRate: sampleRate, language: q['language']);
            channel.sink.add(jsonEncode([
              for (final s in result.segments)
                {'text': s.text, 'start': s.start, 'end': s.end, 'speaker': 'SPEAKER_00'},
            ]));
          } on SttException {
            // no worker: ignore this batch.
          }
        }
      }, onDone: () async {
        await channel.sink.close();
      });
    });
    return handler(req);
  }

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

    // ---- users / profile ----
    if (path == 'v1/users/profile' && method == 'GET') {
      return _json(_users.profile());
    }
    if ((path == 'v1/users/me' || path == 'v1/users/me/profile') && method == 'GET') {
      return _json(_users.profile());
    }
    if (path == 'v1/users/ai-profile') {
      if (method == 'GET') return _json(_users.aiProfile());
      if (method == 'PATCH') {
        return _json(_users.setAiProfile(await _body(req)));
      }
      if (method == 'POST') {
        return _json(_users.setAiProfile(await _body(req)));
      }
      if (method == 'DELETE') {
        _users.deleteAiProfile();
        return Response(204);
      }
    }
    if (path == 'v1/users/ai-profile/refresh' && method == 'POST') {
      return _json(_users.setAiProfile({'profile_text': '基于本地对话自动生成'}));
    }
    if (path == 'v1/users/language') {
      if (method == 'GET') return _json({'language': _db.getSetting('language') ?? 'zh'});
      if (method == 'PATCH') {
        final body = await _body(req);
        final language = body['language'] as String? ?? 'zh';
        _db.setSetting('language', language);
        return _json({'language': language, 'status': 'ok', 'single_language_mode': false});
      }
    }
    if (path == 'v1/users/people') {
      if (method == 'GET') return _json(_users.listPeople());
      if (method == 'POST') {
        final body = await _body(req);
        final id = _uuid.v4();
        _users.upsertPerson(id, body['name'] as String? ?? '');
        return _json({'id': id, 'name': body['name']});
      }
    }
    final personId = _match(path, 'v1/users/people/');
    if (personId != null && !personId.contains('/') && method == 'DELETE') {
      _users.deletePerson(personId);
      return Response(204);
    }
    if (path == 'v1/users/daily-summaries') {
      if (method == 'GET') {
        final q = req.url.queryParameters;
        return _json({
          'summaries': _users.listDailySummaries(
              limit: int.tryParse(q['limit'] ?? '') ?? 30,
              offset: int.tryParse(q['offset'] ?? '') ?? 0),
        });
      }
      if (method == 'POST') {
        final body = await _body(req);
        final date = body['date'] as String? ?? '${DateTime.now()}'.substring(0, 10);
        final summary = _users.buildDailySummary(date);
        _users.upsertDailySummary(summary);
        return _json(summary);
      }
    }
    if (path.startsWith('v1/users/daily-summaries/') && method == 'GET') {
      final date = path.substring('v1/users/daily-summaries/'.length);
      final summary = _users.buildDailySummary(date);
      return _json(summary);
    }
    if (path == 'v1/flags' && method == 'GET') {
      return _json(_users.flags());
    }

    // ---- goals ----
    if (path == 'v1/goals' && method == 'GET') {
      return _json(_users.currentGoal());
    }
    if (path == 'v1/goals/all' && method == 'GET') {
      return _json(_users.listGoals());
    }
    if (path == 'v1/goals' && method == 'POST') {
      final body = await _body(req);
      final id = _uuid.v4();
      _users.upsertGoal({
        'id': id,
        'title': body['title'] ?? '',
        'desired_outcome': body['desired_outcome'] ?? '',
        'status': 'active',
      });
      return _json(_users.getGoal(id));
    }
    final goalId = _match(path, 'v1/goals/');
    if (goalId != null && !goalId.contains('/')) {
      final g = _users.getGoal(goalId);
      if (method == 'GET') {
        return g == null ? _json({'detail': 'Not Found'}, status: 404) : _json(g);
      }
      if (method == 'PATCH' || method == 'DELETE') {
        if (g == null) return _json({'detail': 'Not Found'}, status: 404);
        if (method == 'DELETE') {
          _users.deleteGoal(goalId);
          return Response(204);
        }
        final body = await _body(req);
        _users.upsertGoal({
          'id': goalId,
          'title': body['title'] ?? g['title'],
          'desired_outcome': body['desired_outcome'] ?? g['desired_outcome'],
          'status': body['status'] ?? g['status'],
          'created_at': g['created_at'],
        });
        return _json(_users.getGoal(goalId));
      }
    }

    // ---- folders ----
    if (path == 'v1/folders') {
      if (method == 'GET') return _json(_users.listFolders());
      if (method == 'POST') {
        final body = await _body(req);
        final id = _uuid.v4();
        _users.upsertFolder({
          'id': id,
          'name': body['name'] ?? '未命名文件夹',
          'color': body['color'],
          'description': body['description'],
          'icon': body['icon'],
        });
        return _json(_users.getFolder(id));
      }
    }
    final folderId = _match(path, 'v1/folders/');
    if (folderId != null && !folderId.contains('/')) {
      final f = _users.getFolder(folderId);
      if (method == 'PATCH') {
        if (f == null) return _json({'detail': 'Not Found'}, status: 404);
        final body = await _body(req);
        _users.upsertFolder({
          'id': folderId,
          'name': body['name'] ?? f['name'],
          'color': body['color'] ?? f['color'],
          'description': body['description'] ?? f['description'],
          'icon': body['icon'] ?? f['icon'],
          'created_at': f['created_at'],
        });
        return _json(_users.getFolder(folderId));
      }
      if (method == 'DELETE') {
        _users.deleteFolder(folderId);
        return Response(204);
      }
      if (method == 'GET' && f != null) return _json(f);
    }

    // ---- sync: capture manifest / end ----
    if (path == 'v2/sync-capture-manifest' && method == 'POST') {
      final body = await _body(req);
      final convId = body['conversation_id'] as String? ?? _uuid.v4();
      final files = (body['files'] as List?) ?? const [];
      final manifest = {
        'version': 1,
        'conversation_id': convId,
        'accepted_files': files.length,
        'blobs': <Object>[],
      };
      _db.db.execute(
        'INSERT INTO sync_ledger (id, kind, created_at, payload) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
        [convId, 'manifest', DateTime.now().toIso8601String(), jsonEncode(manifest)],
      );
      return _json({'manifest': jsonEncode(manifest)});
    }
    if (path == 'v2/sync-capture-end' && method == 'POST') {
      final body = await _body(req);
      _db.db.execute(
        'INSERT INTO sync_ledger (id, kind, created_at, payload) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
        [
          'end-${_uuid.v4()}',
          'capture_end',
          DateTime.now().toIso8601String(),
          jsonEncode(body),
        ],
      );
      return _json({'accepted': true, 'retry': false});
    }
    if (path == 'v2/sync-local-files' && method == 'POST') {
      return _json({'job_id': 'sync-${_uuid.v4()}', 'status': 'queued'});
    }
    if (path.startsWith('v2/sync-local-files/') && method == 'GET') {
      return _json({'status': 'completed', 'processed': 0});
    }

    // ---- desktop messages (durable chat persistence, separate from v2/messages) ----
    if (path == 'v2/desktop/messages') {
      final q = req.url.queryParameters;
      if (method == 'GET') {
        return _json(_chat
            .messages(chatSessionId: q['chat_session_id'], limit: 100)
            .map((m) => m.toWire())
            .toList());
      }
      if (method == 'POST') {
        final body = await _body(req);
        final text = (body['text'] as String? ?? '').trim();
        if (text.isEmpty) {
          return _json({'detail': 'text must not be empty'}, status: 400);
        }
        final m = ChatMessage(
          id: _uuid.v4(),
          role: body['sender'] as String? ?? 'user',
          text: text,
          createdAt: DateTime.now(),
          chatSessionId: body['chat_session_id'] as String?,
        );
        _chat.insertMessage(m);
        return _json(m.toWire());
      }
      if (method == 'DELETE') {
        _chat.clearMessages(chatSessionId: q['chat_session_id']);
        return Response(204);
      }
    }

    // ---- misc desktop: prompts, subscription, model pick, updates feed ----
    if (path == 'v2/desktop/prompts' && method == 'GET') {
      return _json({'version': 'local', 'prompts': <Object>[]});
    }
    if (path == 'v1/users/me/subscription' && method == 'GET') {
      return _json({
        'plan': 'local',
        'status': 'active',
        'is_paid': false,
        'features': <Object>[],
      });
    }
    if (path == 'v1/users/me/usage-quota' && method == 'GET') {
      return _json({'used': 0, 'limit': null, 'unlimited': true});
    }
    if (path == 'v1/users/me/trial' && method == 'GET') {
      return _json({'eligible': false, 'active': false});
    }
    if (path == 'v1/auto/model-pick' && method == 'GET') {
      return _json({'provider': 'local', 'model': 'deepseek-flash'});
    }
    if (path.startsWith('v2/desktop/update-feed') && method == 'GET') {
      return _json({'feed_url': '', 'channel': 'local', 'version': 'local'});
    }
    if (path == 'v1/users/fcm-token' && method == 'POST') {
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/time-zone' && method == 'PUT') {
      return _json({'status': 'ok'});
    }

    // ---- desktop glue / realtime ----
    if (path == 'v2/realtime/session' && method == 'POST') {
      // Ephemeral realtime token mint: a local build has no hanging realtime
      // provider. Return an inert session the client treats as usable-soon;
      // the desktop voice hub degrades when its provider is unreachable.
      return _json({
        'session_id': 'realtime-${_uuid.v4()}',
        'provider': req.url.queryParameters['provider'] ?? 'local',
        'client_secret': {'value': _uuid.v4().replaceAll('-', '')},
        'expires_at': DateTime.now().add(const Duration(minutes: 10)).toIso8601String(),
      });
    }
    if (path == 'v3/speech-profile/stt-availability' && method == 'GET') {
      return _json({'available': true, 'provider': 'local'});
    }
    if (path.startsWith('v1/proxy/gemini')) {
      // Desktop Gemini proxy: route generateContent/embedContent to the local
      // LLM. Most call sites tolerate an OpenAI-shaped reply; embed batching
      // is stubbed with a dimension-consistent zero vector.
      if (method == 'POST') {
        final body = await _body(req);
        if (path.contains('embed')) {
          return _json(_embedReply(body));
        }
        final messages = _geminiMessages(body);
        try {
          final reply = await _llm.complete(messages);
          return _json(_geminiContentReply(reply.content));
        } on LlmException catch (e) {
          return _json({'error': {'message': e.message}}, status: 502);
        }
      }
    }

    // ---- search overview ----
    if (path == 'v1/search/overview' && method == 'GET') {
      return _json({
        'memories': _knowledge.listMemories().length,
        'people': _users.listPeople().length,
        'folders': _users.listFolders(),
        'places': 0,
        'recaps': 0,
        'starred': 0,
      });
    }

    // ---- apps / personas ----
    if (path == 'v2/apps' && method == 'GET') {
      return _json({
        'data': _apps(),
        'count': _apps().length,
        'has_more': false,
        'offset': 0,
        'limit': 0,
      });
    }
    if ((path == 'v1/apps' || path == 'v1/apps/enabled') && method == 'GET') {
      if (path == 'v1/apps/enabled') {
        return _json(_apps().map((a) => a['id']).toList());
      }
      return _json(_apps());
    }
    if (path == 'v1/personas' && method == 'GET') {
      return _json(_apps().firstWhere((a) => a['category'] == 'persona',
          orElse: () => <String, dynamic>{}));
    }
    final appId = _match(path, 'v1/apps/');
    if (appId != null && !appId.contains('/')) {
      if (method == 'GET') {
        final app = _apps().where((a) => a['id'] == appId).firstOrNull;
        return app == null
            ? _json({'detail': 'Not Found'}, status: 404)
            : _json(app);
      }
      if (method == 'POST') {
        // enable/disable use query (not body); reviews post under {id}/review.
        return _json({'status': 'ok'});
      }
    }
    if (path.startsWith('v1/apps/unapproved') && method == 'GET') {
      return _json(<Object>[]);
    }

    // ---- memories extract ----
    if (path == 'v1/memories/extract' && method == 'POST') {
      final body = await _body(req);
      final text = (body['text'] as String? ?? '').trim();
      if (text.isEmpty) {
        return _json({'detail': 'text must not be empty'}, status: 400);
      }
      try {
        final reply = await _llm.complete([
          {'role': 'system', 'content': _memoryExtractPrompt},
          {'role': 'user', 'content': text},
        ], temperature: 0.1);
        final facts = _memoryFromReply(reply.content);
        final created = <Map<String, dynamic>>[];
        for (final f in facts) {
          final m = Memory(id: _uuid.v4(), content: f, createdAt: DateTime.now());
          _knowledge.upsertMemory(m);
          created.add(m.toWire());
        }
        return _json({'memories': created});
      } on LlmException catch (e) {
        return _json({'detail': e.message}, status: 502);
      }
    }

    // ---- home feed ----
    if (path == 'v1/home/feed' && method == 'GET') {
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 20;
      final items = _knowledge.listMemories(limit: limit)
          .map((m) => {'kind': 'memory', 'content': m.content})
          .toList();
      return _json({
        'generation': 'local',
        'items': items,
        'has_more': false,
        'next_cursor': '',
        'truncated': false,
      });
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

  static const _memoryExtractPrompt =
      '从下面文本中抽取值得长期记住的事实，输出严格的 JSON 数组 ["事实1","事实2"]。'
      '若没有，输出 []。只输出 JSON。';

  static List<Map<String, dynamic>> _apps() =>
      _localApps.map((a) => Map<String, dynamic>.from(a)).toList();

  static List<String> _memoryFromReply(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      return decoded is List ? decoded.map((e) => e.toString()).toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  /// Gemini `{contents:[{parts:[{text}]}]}` → OpenAI role/content pairs.
  static List<Map<String, String>> _geminiMessages(Map<String, dynamic> body) {
    final contents = body['contents'] as List?;
    if (contents == null) {
      final prompt = body['prompt'] as String?;
      return [
        {'role': 'user', 'content': prompt ?? ''},
      ];
    }
    return contents.map((c) {
      final m = c as Map;
      final role = m['role'] as String? ?? 'user';
      final text = ((m['parts'] as List?) ?? const [])
          .map((p) => (p as Map)['text']?.toString() ?? '')
          .join('\n');
      return {'role': role == 'model' ? 'assistant' : 'user', 'content': text};
    }).toList();
  }

  /// Gemini `generateContent` reply: `{candidates:[{content:{parts:[{text}]}}]}`.
  static Map<String, dynamic> _geminiContentReply(String text) => {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': text},
              ],
              'role': 'model',
            },
            'finishReason': 'STOP',
          }
        ],
      };

  /// Gemini `embedContent`/`batchEmbedContents` reply with a fixed 1024-dim
  /// zero vector — enough shape for the desktop's cosine code to run without a
  /// real embedding provider.
  static Map<String, dynamic> _embedReply(Map<String, dynamic> body) {
    const dim = 1024;
    final zero = List<double>.filled(dim, 0);
    if (body['requests'] is List) {
      final n = (body['requests'] as List).length;
      return {
        'embeddings': List.generate(n, (_) => {'values': zero}),
      };
    }
    return {
      'embedding': {'values': zero},
    };
  }

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