import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'knowledge.dart';
import 'llm_client.dart';
import 'store.dart';
import 'user_store.dart';

const _uuid = Uuid();

/// Remaining client-called routes over the Omi OpenAPI surface, plus a
/// well-formed fallback so a client never sees a bare 404 for a route it is
/// known to call. Anything not matched here and not in `Api` returns null and
/// the caller falls through to 404 (unknown paths stay 404, mirroring FastAPI).
class ExtraRoutes {
  // Named params cannot be private fields in Dart; init list required.
  // ignore_for_file: prefer_initializing_formals
  ExtraRoutes({
    required ConversationStore conversations,
    required KnowledgeStore knowledge,
    required UserStore users,
    required LlmClient llm,
  })  : _conversations = conversations,
        _knowledge = knowledge,
        _users = users,
        _llm = llm;

  final ConversationStore _conversations;
  final KnowledgeStore _knowledge;
  final UserStore _users;
  final LlmClient _llm;

  Future<Response?> handle(Request req, Future<Map<String, dynamic>> Function() readBody) async {
    final path = req.url.path;
    final m = req.method;
    final q = req.url.queryParameters;

    // ---- conversations extras ----
    if (path == 'v1/conversations/live' && m == 'GET') {
      final list = _conversations.list(limit: 1);
      return list.isEmpty ? _json(null) : _json(list.first.toJson());
    }
    if (path == 'v1/conversations/search' && m == 'POST') {
      final body = await readBody();
      final needle = (body['query'] ?? body['text'] ?? '').toString().toLowerCase();
      final hits = _conversations
          .list(limit: 50)
          .where((c) => (c.title ?? '').toLowerCase().contains(needle))
          .map((c) => c.toJson())
          .toList();
      return _json(hits);
    }
    if (path == 'v1/conversations/merge' && m == 'POST') {
      return _json({'status': 'ok', 'merged': 0});
    }
    if (path == 'v1/conversations/topic' && m == 'POST') {
      final body = await readBody();
      final id = body['conversation_id'] as String?;
      final conv = id == null ? null : _conversations.get(id);
      if (conv == null) return _json({'topic': ''});
      try {
        final reply = await _llm.complete([
          {
            'role': 'system',
            'content': '用不超过10个字概括这段对话的主题，只输出主题本身。',
          },
          {
            'role': 'user',
            'content': (conv.transcript ?? const []).map((s) => s.text).join('\n'),
          },
        ], temperature: 0.2);
        return _json({'topic': reply.content.trim()});
      } on LlmException {
        return _json({'topic': ''});
      }
    }
    if (path == 'v1/conversations/task-presence' && m == 'POST') {
      return _json({'with_tasks': <Object>[], 'without_tasks': <Object>[]});
    }
    if (path == 'v1/conversations/with-tasks/page' && m == 'POST') {
      return _json({'conversations': <Object>[], 'has_more': false});
    }
    if (path == 'v1/conversations/hidden-noise-counts' && m == 'GET') {
      return _json({'hidden': 0, 'noise': 0});
    }

    // ---- conversation sub-resources ----
    final convSub = _sub(path, 'v1/conversations/');
    if (convSub != null) {
      final id = convSub.$1;
      final tail = convSub.$2;
      if (tail.isEmpty) return null; // handled by Api
      // These return a 404 when the conversation is missing and are already
      // handled by Api for the found case; don't mask that here.
      if (tail == 'finalize' || tail == 'reprocess') return null;
      switch (tail) {
        case 'summary':
          if (m == 'GET' || m == 'PATCH') {
            return _json({'summary': '', 'status': 'ok'});
          }
        case 'summary/stream':
          return _sse('data: \n\ndone: \n\n');
        case 'segments/text':
          if (m == 'GET') {
            return _json(_conversations.segments(id).map((s) => s.toJson()).toList());
          }
        case 'transcripts':
          return _json(_conversations.segments(id).map((s) => s.toJson()).toList());
        case 'segments/assign-bulk':
        case 'recording-speakers':
          return _json({'status': 'ok', 'speakers': <Object>[]});
        case 'folder':
          return _json({'status': 'ok'});
        case 'analysis':
        case 'analytics':
          return _json({'status': 'ok'});
        case 'finalization':
          final c = _conversations.get(id);
          return _json({'status': c?.status ?? 'completed', 'conversation_id': id});
        case 'action-items':
          if (m == 'GET') {
            return _json({
              'action_items': [
                for (final a in _knowledge.listActionItems())
                  if (a.conversationId == id) a.toWire(),
              ],
              'has_more': false,
              'truncated': false,
            });
          }
          return _json({'status': 'ok'});
        case 'action-items/count':
          final n = _knowledge
              .listActionItems()
              .where((a) => a.conversationId == id)
              .length;
          return _json({'count': n});
        case 'recording':
          return _json({'has_recording': false});
        case 'screenshots':
        case 'photos':
          return m == 'DELETE' ? Response(204) : _json(<Object>[]);
        case 'entities':
          return _json(<Object>[]);
        case 'mutations':
          return _json({'status': 'ok'});
        case 'events':
        case 'screenshot-sharing':
        case 'calendar-event':
          return m == 'DELETE' ? Response(204) : _json({'status': 'ok'});
        case 'shared':
          return _json(<Object>[]);
        case 'share-recipients':
          return _json(<Object>[]);
        case 'share-email':
          return _json({'status': 'ok'});
        case 'suggested-apps':
          return _json(<Object>[]);
        case 'test-prompt':
          return _json({'status': 'ok'});
        case 'capture-group/separate':
        case 'calendar-event/auto-link':
          return _json({'status': 'ok'});
        case 'speakers':
          return _json({'status': 'ok'});
      }
      return m == 'DELETE' ? Response(204) : _json({'status': 'ok'});
    }

    // ---- memories extras ----
    if (path == 'v3/memories/ledger-history' && m == 'GET') {
      return _json({'entries': <Object>[], 'has_more': false});
    }
    if (path == 'v3/memories/review-queue' && m == 'GET') {
      return _json({'items': <Object>[], 'count': 0});
    }
    if (path.startsWith('v3/memories/review-queue/')) {
      return _json({'status': 'ok'});
    }
    final memSub = _sub(path, 'v3/memories/');
    if (memSub != null && memSub.$2.isNotEmpty) {
      final id = memSub.$1;
      final tail = memSub.$2;
      switch (tail) {
        case 'visibility':
        case 'review':
        case 'revert':
        case 'baseline':
        case 'use':
        case 'read':
          final mem = _knowledge.getMemory(id);
          return _json(mem?.toWire() ?? {'status': 'ok'});
      }
      return _json({'status': 'ok'});
    }

    // ---- action items extras ----
    if (path == 'v1/action-items/ids' && m == 'GET') {
      return _json(_knowledge.listActionItems().map((a) => a.id).toList());
    }
    if (path == 'v1/action-items/pending-sync' && m == 'GET') {
      return _json({'items': <Object>[], 'server_time': DateTime.now().toIso8601String()});
    }
    if (path == 'v1/action-items/sync-batch' && m == 'PATCH') {
      return _json({'applied': 0, 'conflicts': <Object>[]});
    }
    if (path == 'v1/action-items/batch' && m == 'POST') {
      final body = await readBody();
      final items = (body['action_items'] as List?) ?? const [];
      final created = <Map<String, dynamic>>[];
      for (final raw in items) {
        final map = raw as Map;
        final desc = (map['description'] ?? map['text'] ?? '').toString().trim();
        if (desc.isEmpty) continue;
        final a = ActionItem(id: _uuid.v4(), description: desc, createdAt: DateTime.now());
        _knowledge.upsertActionItem(a);
        created.add(a.toWire());
      }
      return _json({'action_items': created});
    }
    if (path == 'v1/action-items/batch') return _json({'status': 'ok'});
    if (path == 'v1/action-items/batch-delete' && m == 'POST') {
      final body = await readBody();
      for (final id in (body['ids'] as List? ?? const [])) {
        _knowledge.deleteActionItem(id.toString());
      }
      return _json({'status': 'ok'});
    }
    if (path == 'v1/action-items/search' && m == 'GET') {
      final needle = (q['query'] ?? '').toLowerCase();
      return _json({
        'action_items': _knowledge
            .listActionItems()
            .where((a) => a.description.toLowerCase().contains(needle))
            .map((a) => a.toWire())
            .toList(),
      });
    }
    if (path == 'v1/action-items/share' && m == 'POST') {
      return _json({'share_token': 'local-share', 'status': 'ok'});
    }
    if (path.startsWith('v1/action-items/shared/') && m == 'GET') {
      return _json({'action_items': <Object>[]});
    }
    if (path == 'v1/action-items/accept' && m == 'POST') {
      return _json({'status': 'ok'});
    }
    if (path == 'v1/action-items/restore-legacy-conversation-items' && m == 'POST') {
      return _json({'status': 'ok', 'restored': 0});
    }
    final aiSub = _sub(path, 'v1/action-items/');
    if (aiSub != null && aiSub.$2 == 'completed' && m == 'PATCH') {
      final id = aiSub.$1;
      final a = _knowledge.getActionItem(id);
      if (a == null) return _json({'detail': 'Not Found'}, status: 404);
      final toggled = ActionItem(
        id: a.id,
        description: a.description,
        completed: !a.completed,
        createdAt: a.createdAt,
        completedAt: !a.completed ? DateTime.now() : null,
        conversationId: a.conversationId,
      );
      _knowledge.upsertActionItem(toggled);
      return _json(toggled.toWire());
    }

    // ---- staged tasks / candidates / screen task ----
    if (path == 'v1/staged-tasks' && m == 'POST') {
      final body = await readBody();
      return _json({'id': _uuid.v4(), 'status': 'staged', 'description': body['description']});
    }
    if (path == 'v1/staged-tasks/promote' && m == 'POST') {
      return _json({'status': 'ok', 'promoted': 0});
    }
    if (path == 'v1/screen-task/gate' && m == 'POST') {
      return _json({'admitted': true, 'reason': 'local'});
    }
    if (path == 'v1/screen-task/admission' && m == 'POST') {
      return _json({'admitted': true});
    }
    if (path == 'v1/candidates' && m == 'GET') {
      return _json({'candidates': <Object>[]});
    }
    if (path.startsWith('v1/candidates') && m != 'GET') {
      return _json({'status': 'ok'});
    }

    // ---- goals extras ----
    if (path == 'v1/goals/suggest' && m == 'GET') return _json(null);
    if (path == 'v1/goals/canonical' && m == 'GET') return _json(_users.listGoals());
    if (path == 'v1/goals/canonical/list' && m == 'GET') return _json(_users.listGoals());
    if (path == 'v1/goals/advice' && m == 'GET') return _json({'advice': ''});
    if (path == 'v1/goals/extract-progress' && m == 'POST') {
      return _json({'status': 'ok', 'updated': 0});
    }
    final goalSub = _sub(path, 'v1/goals/');
    if (goalSub != null && goalSub.$2.isNotEmpty) {
      final id = goalSub.$1;
      final g = _users.getGoal(id) ?? <String, dynamic>{};
      final tail = goalSub.$2;
      if (tail == 'progress' && m == 'PATCH') {
        final body = await readBody();
        return _json({'status': 'ok', 'current_value': body['current_value'] ?? g['current_value']});
      }
      if (tail == 'advice') return _json({'advice': ''});
      if (tail == 'history') return _json({'events': <Object>[]});
      if (tail == 'detail') return _json(g);
      return _json({'status': 'ok'});
    }

    // ---- folders extras ----
    if (path == 'v1/folders/reorder' && m == 'PATCH') return _json({'status': 'ok'});
    final folderSub = _sub(path, 'v1/folders/');
    if (folderSub != null && folderSub.$2.isNotEmpty) {
      final tail = folderSub.$2;
      if (tail == 'conversations' || tail == 'conversations/bulk-move') {
        return m == 'GET' ? _json(<Object>[]) : _json({'status': 'ok'});
      }
      return _json({'status': 'ok'});
    }

    // ---- v2 messages extras ----
    if (path == 'v2/initial-message' && m == 'POST') {
      final appId = q['app_id'] ?? '';
      final appName = appId.isEmpty ? '小蜗' : appId;
      return _json({
        'id': _uuid.v4(),
        'text': '你好，我是$appName。有什么可以帮你？',
        'sender': 'ai',
        'type': 'text',
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    if (path == 'v2/voice-messages' && m == 'POST') {
      return _sse('data: 收到语音\n\ndone: \n\n');
    }
    if (path.startsWith('v2/messages/device-tool')) {
      return _json({'status': 'accepted'});
    }
    if (path == 'v2/messages/share' && m == 'POST') {
      return _json({'share_token': 'local-share', 'status': 'ok'});
    }
    if (path.startsWith('v2/messages/shared/') && m == 'GET') return _json(<Object>[]);
    final msgSub = _sub(path, 'v2/messages/');
    if (msgSub != null && (msgSub.$2 == 'report' || msgSub.$2 == 'rating')) {
      return _json({'status': 'ok'});
    }
    if (path == 'v2/chat/generate-title' && m == 'POST') {
      return _json({'title': '新的对话'});
    }
    if (path == 'v2/chat/materialize-prompts' && m == 'POST') {
      return _json({'prompts': <Object>[]});
    }
    if (path == 'v1/chat/materialize-prompts' && m == 'POST') {
      return _json({'prompts': <Object>[]});
    }
    if (path == 'v1/chat/deferrals' && m == 'POST') return _json({'status': 'ok'});
    final receiptSub = _sub(path, 'v1/chat/receipts/');
    if (receiptSub != null && receiptSub.$2 == 'undo') return _json({'status': 'ok'});

    // ---- files ----
    if ((path == 'v2/files' || path == 'v2/files/video') && m == 'POST') {
      return _json({'file_id': _uuid.v4(), 'status': 'uploaded', 'url': ''});
    }

    // ---- apps extras ----
    if (path == 'v2/apps/search' && m == 'GET') {
      return _json({'data': <Object>[], 'count': 0, 'has_more': false});
    }
    if (path.startsWith('v2/apps/capability/') && m == 'GET') {
      return _json({'data': <Object>[], 'groups': <Object>[], 'count': 0});
    }
    if (path == 'v1/app-capabilities' && m == 'GET') return _json(<Object>[]);
    if (path == 'v1/app-categories' && m == 'GET') return _json(<Object>[]);
    if (path == 'v1/app/thumbnails' && m == 'GET') return _json(<Object>[]);
    if (path == 'v1/apps/popular' && m == 'GET') return _json(<Object>[]);
    if (path == 'v1/apps/public/unapproved' && m == 'GET') return _json(<Object>[]);
    if ((path == 'v1/apps/enable' || path == 'v1/apps/disable') && m == 'POST') {
      return _json({'status': 'ok', 'app_id': q['app_id']});
    }
    if (path == 'v1/apps/review' && m == 'POST') return _json({'status': 'ok'});
    if (path.startsWith('v1/app/') && m == 'POST') {
      return _json({'status': 'ok', 'text': '', 'emoji': ''});
    }
    final appSub = _sub(path, 'v1/apps/');
    if (appSub != null && appSub.$2.isNotEmpty) {
      final tail = appSub.$2;
      if (tail == 'reviews') return _json(<Object>[]);
      if (tail == 'review' || tail == 'review/reply') return _json({'status': 'ok'});
      if (tail == 'keys' || tail == 'keys/scopes') {
        return m == 'GET' ? _json(<Object>[]) : _json({'keys': <Object>[]});
      }
      if (tail.startsWith('keys/')) return _json({'status': 'ok'});
      if (tail == 'subscription') return _json({'subscribed': false});
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/personas')) {
      return _json(<Object>[]);
    }

    // ---- tools (agent) ----
    if (path.startsWith('v1/tools/')) {
      if (m == 'GET' && path.contains('memories')) {
        return _json({'data': _knowledge.listMemories().map((x) => x.toWire()).toList()});
      }
      if (m == 'GET' && path.contains('conversations')) {
        return _json({'data': _conversations.list().map((c) => c.toJson()).toList()});
      }
      if (m == 'POST' && path.contains('search')) {
        final body = await readBody();
        final needle = (body['query'] ?? '').toString();
        if (path.contains('memories')) {
          return _json({
            'data': _knowledge.searchMemories(needle).map((x) => x.toWire()).toList(),
          });
        }
        return _json({
          'data': _conversations
              .list()
              .where((c) => (c.title ?? '').contains(needle))
              .map((c) => c.toJson())
              .toList(),
        });
      }
      return _json({'data': <Object>[]});
    }
    if (path == 'v1/agent/tools' && m == 'GET') return _json(<Object>[]);
    if (path == 'v1/agent/execute-tool' && m == 'POST') {
      return _json({'status': 'ok', 'result': null});
    }

    // ---- speech profile ----
    if (path.startsWith('v3/speech-profile') || path.startsWith('v4/speech-profile')) {
      if (path.endsWith('/stt-availability') || path.endsWith('/status')) {
        return _json({'available': true, 'status': 'ready', 'provider': 'local'});
      }
      if (path.endsWith('/expand')) return _json({'words': <Object>[]});
      if (m == 'GET') return _json({'has_profile': false, 'words': <Object>[], 'status': 'ready'});
      return _json({'status': 'ok'});
    }
    if (path == 'v3/upload-audio' && m == 'POST') {
      return _json({'status': 'ok', 'sample_id': _uuid.v4()});
    }

    // ---- sync audio ----
    if (path.startsWith('v1/sync/audio/')) {
      if (path.endsWith('/urls')) return _json({'urls': <Object>[]});
      if (path.endsWith('/precache')) return _json({'status': 'ok', 'cached': 0});
      return _json({'status': 'ok'});
    }

    // ---- knowledge graph ----
    if (path == 'v1/knowledge-graph') {
      if (m == 'GET') return _json({'nodes': <Object>[], 'edges': <Object>[]});
      if (m == 'DELETE') return Response(204);
      return _json({'status': 'ok'});
    }
    if (path == 'v1/knowledge-graph/rebuild' ||
        path == 'v1/knowledge-graph/extract' ||
        path == 'v1/knowledge-graph/canonical') {
      return _json({'status': 'ok', 'nodes': <Object>[], 'edges': <Object>[]});
    }
    if (path == 'v1/connectors/synthesize' && m == 'POST') {
      return _json({'status': 'ok', 'memories': <Object>[]});
    }

    // ---- users extras ----
    if (path == 'v1/users/me/usage' && m == 'GET') {
      return _json({'used': 0, 'limit': null, 'unlimited': true});
    }
    if (path == 'v1/users/available-languages' && m == 'GET') {
      return _json({'languages': ['zh', 'en']});
    }
    if (path == 'v1/users/onboarding') {
      if (m == 'GET') return _json({'completed': true, 'step': 'done'});
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/transcription-preferences') {
      if (m == 'GET') return _json({'single_language_mode': false, 'vocabulary': <Object>[]});
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/training-data-opt-in') {
      return _json({'opted_in': false});
    }
    if (path == 'v1/users/store-recording-permission' && m == 'POST') {
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/daily-summary-settings') {
      if (m == 'GET') return _json({'enabled': true, 'time': '21:00'});
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/daily-summary-settings/test' && m == 'POST') {
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/daily-summaries/search' && m == 'GET') {
      final needle = (q['query'] ?? '').toLowerCase();
      return _json({
        'summaries': _users
            .listDailySummaries()
            .where((s) => (s['overview'] ?? '').toString().toLowerCase().contains(needle))
            .toList(),
      });
    }
    final dsSub = _sub(path, 'v1/users/daily-summaries/');
    if (dsSub != null && dsSub.$2.isNotEmpty) {
      if (dsSub.$2 == 'regenerate') {
        final s = _users.buildDailySummary(dsSub.$1);
        _users.upsertDailySummary(s);
        return _json(s);
      }
      return _json({'status': 'ok'});
    }
    final personSub = _sub(path, 'v1/users/people/');
    if (personSub != null && personSub.$2.isNotEmpty) {
      final tail = personSub.$2;
      if (tail == 'name' && m == 'PATCH') {
        final body = await readBody();
        _users.upsertPerson(personSub.$1, body['name'] as String? ?? '');
        return _json({'status': 'ok'});
      }
      if (tail == 'pinned') return _json({'status': 'ok'});
      if (tail == 'voice-matches') return _json({'matches': <Object>[]});
      if (tail.startsWith('speech-samples')) return _json({'status': 'ok'});
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/export' && m == 'GET') {
      return _json({
        'uid': 'local-dev-user',
        'conversations': _conversations.list().map((c) => c.toJson()).toList(),
        'memories': _knowledge.listMemories().map((x) => x.toWire()).toList(),
      });
    }
    if (path == 'v1/users/delete-account') {
      return _json({'status': 'local_only_no_account'});
    }
    if (path == 'v1/users/deletion-status' && m == 'GET') {
      return _json({'status': 'active'});
    }
    if (path == 'v1/users/restore-account' && m == 'POST') {
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/geolocation' && m == 'POST') return _json({'status': 'ok'});
    if (path == 'v1/users/client-state' && m == 'GET') return _json(<String, dynamic>{});
    if (path == 'v1/users/assistant-settings' ||
        path == 'v1/users/voice-profile-settings' ||
        path == 'v1/users/notification-settings' ||
        path == 'v1/users/mentor-notification-settings' ||
        path == 'v1/users/location-context-consent' ||
        path == 'v1/users/private-cloud-sync' ||
        path == 'v1/users/release-channel' ||
        path == 'v1/users/preferences/app' ||
        path == 'v1/users/budget-choice') {
      if (m == 'GET') return _json(<String, dynamic>{});
      return _json({'status': 'ok'});
    }
    if (path == 'v1/users/me/byok-active') {
      return m == 'DELETE' ? Response(204) : _json({'active': false, 'keys': <Object>[]});
    }
    if (path == 'v1/users/me/paywall' && m == 'GET') {
      return _json({'paywalled': false, 'reason': 'local'});
    }
    if (path == 'v1/users/me/referral' && m == 'GET') {
      return _json({'code': 'LOCAL', 'credits': 0});
    }
    if (path.startsWith('v1/users/me/llm-usage') && m == 'GET') {
      return _json({'total': 0, 'top_features': <Object>[]});
    }
    if (path == 'v1/users/me/subscription' || path == 'v1/payments/subscription') {
      return _json({'plan': 'local', 'status': 'active', 'is_paid': false});
    }
    if (path == 'v1/fair-use/status' && m == 'GET') {
      return _json({'limited': false, 'reason': 'local'});
    }
    if (path.startsWith('v1/users/analytics/') && m == 'POST') {
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/users/stats/') && m == 'GET') {
      return _json({'count': 0});
    }
    if (path.startsWith('v1/users/developer/')) return _json({'status': 'ok'});

    // ---- billing / payments / stripe / paypal: local = no billing ----
    if (path.startsWith('v1/payments/') ||
        path.startsWith('v1/stripe/') ||
        path.startsWith('v1/paypal/') ||
        path.startsWith('v1/payment-methods/') ||
        path.startsWith('v2/payments/') ||
        path.startsWith('v2/users/me/referral')) {
      if (m == 'GET') {
        return _json({'plans': <Object>[], 'status': 'local', 'subscribed': false});
      }
      return _json({'status': 'local', 'url': ''});
    }

    // ---- announcements / firmware / updates ----
    if (path.startsWith('v1/announcements')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v2/firmware/') && m == 'GET') {
      return _json({'version': 'local', 'url': ''});
    }

    // ---- episodes / review / entities / attention ----
    if (path == 'v1/episodes/live' && m == 'GET') return _json(null);
    if (path.startsWith('v1/episodes')) {
      if (m == 'GET') {
        return path == 'v1/episodes' ? _json(<Object>[]) : _json(null);
      }
      return _json({'status': 'ok'});
    }
    if (path == 'v1/entities' && m == 'GET') return _json(<Object>[]);
    if (path.startsWith('v1/entities/')) {
      return m == 'GET' ? _json({'entity': null, 'page': ''}) : _json({'status': 'ok'});
    }
    if (path.startsWith('v1/review/') || path.startsWith('v2/review/')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/pending-work') ||
        path.startsWith('v1/attention-items') ||
        path.startsWith('v1/what-matters-now') ||
        path.startsWith('v1/work-intents') ||
        path.startsWith('v1/proactivity/')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }

    // ---- screen activity / frames ----
    if (path == 'v1/screen-activity' || path == 'v1/screen-activity/summary') {
      return m == 'GET' ? _json({'items': <Object>[]}) : _json({'status': 'ok'});
    }
    if (path == 'v1/screen-activity/sync' && m == 'POST') {
      return _json({'status': 'ok', 'accepted': 0});
    }
    if (path.startsWith('v1/screen-frame-egress/') || path.startsWith('v1/frame-requests')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }

    // ---- speaker tag prompts ----
    if (path.startsWith('v1/speaker-tag-prompts')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }

    // ---- imports / integrations / messaging / phone / task-integrations ----
    if (path.startsWith('v1/import/')) {
      if (m == 'GET') return _json({'jobs': <Object>[]});
      return _json({'job_id': _uuid.v4(), 'status': 'queued'});
    }
    if (path.startsWith('v1/integrations/')) {
      if (m == 'GET') return _json({'connected': false, 'status': 'not_connected'});
      if (m == 'DELETE') return Response(204);
      return _json({'status': 'ok', 'oauth_url': ''});
    }
    if (path.startsWith('v1/messaging/')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/phone/')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/task-integrations') || path.startsWith('v1/task-intelligence')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/sync/')) {
      return _json({'status': 'ok'});
    }

    // ---- calendar ----
    if (path.startsWith('v1/calendar/')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }

    // ---- workstreams / wrapped / csat / jit / dev / mcp / device ----
    if (path.startsWith('v1/workstreams/')) {
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/wrapped/')) {
      return _json({'year': q['year'] ?? '', 'sections': <Object>[]});
    }
    if (path.startsWith('v1/csat/')) {
      if (m == 'GET') return _json({'config': <String, dynamic>{}, 'ratings': <Object>[]});
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/jit/')) {
      return _json({'status': 'ok', 'snapshot': null, 'decision': null});
    }
    if (path.startsWith('v1/dev/')) {
      if (path.contains('conversations') && m == 'GET') {
        return _json(_conversations.list().map((c) => c.toJson()).toList());
      }
      if (path.contains('memories') && m == 'GET') {
        return _json(_knowledge.listMemories().map((x) => x.toWire()).toList());
      }
      if (path.contains('action-items') && m == 'GET') {
        return _json({
          'action_items': _knowledge.listActionItems().map((a) => a.toWire()).toList(),
        });
      }
      if (path.contains('goals') && m == 'GET') return _json(_users.listGoals());
      if (path.contains('folders') && m == 'GET') return _json(_users.listFolders());
      if (path.contains('people') && m == 'GET') return _json(_users.listPeople());
      if (path.contains('profile') && m == 'GET') return _json(_users.profile());
      if (path.contains('daily-summaries') && m == 'GET') {
        return _json({'summaries': _users.listDailySummaries()});
      }
      if (path.contains('keys')) {
        return m == 'GET' ? _json(<Object>[]) : _json({'key': 'local-dev-key'});
      }
      if (m == 'GET') return _json(<Object>[]);
      return _json({'status': 'ok'});
    }
    if (path == 'v1/mcp' || path == 'v1/mcp/sse' || path.startsWith('v1/mcp/')) {
      return _json({
        'jsonrpc': '2.0',
        'result': {'tools': <Object>[]},
        'id': null,
      });
    }
    if (path.startsWith('v1/mobile/') || path.startsWith('v1/device')) {
      return _json({'status': 'ok'});
    }
    if (path.startsWith('v1/capture/')) return _json({'status': 'ok'});
    if (path == 'v2/capture-coverage' && m == 'GET') {
      return _json({'coverage': 'unknown'});
    }
    if (path == 'v1/home/feed/prepare' && m == 'POST') return _json({'status': 'ok'});
    if (path == 'v1/account/cutover/control' && m == 'GET') {
      return _json({'enabled': false});
    }
    if (path == 'v1/workflow-migrations/task-goal-links' && m == 'POST') {
      return _json({'status': 'ok', 'linked': 0});
    }

    return null;
  }

  /// Splits `<prefix><id>/<tail>` into (id, tail); tail '' when no sub-path.
  static (String, String)? _sub(String path, String prefix) {
    if (!path.startsWith(prefix)) return null;
    final rest = path.substring(prefix.length);
    if (rest.isEmpty) return null;
    final slash = rest.indexOf('/');
    return slash < 0 ? (rest, '') : (rest.substring(0, slash), rest.substring(slash + 1));
  }
}

Response _json(Object? data, {int status = 200}) => Response(
      status,
      body: jsonEncode(data),
      headers: {'content-type': 'application/json'},
    );

Response _sse(String body) => Response.ok(
      Stream<List<int>>.value(utf8.encode(body)),
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );