import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'conversation.dart';
import 'db.dart';
import 'store.dart';
import 'tts.dart';
import 'tts_client.dart';

const _uuid = Uuid();

/// Single local user. Any Firebase-shaped Bearer maps here.
const kLocalUserId = 'local-dev-user';

/// Routes so far. Each new domain adds a branch; unknown paths fall
/// through to a JSON 404 that mimics FastAPI's `{"detail": "Not Found"}`.
class Api {
  Api(this._db, {TtsClient? tts}) : _conversations = ConversationStore(_db) {
    _tts = tts ?? TtsClient();
  }

  final LocalDb _db;
  final ConversationStore _conversations;
  late final TtsClient _tts;

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
        return _json(_conversations.toWire(id));
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