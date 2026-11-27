import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'conversation.dart';
import 'knowledge.dart';
import 'llm_client.dart';
import 'provider_surfaces.dart';
import 'store.dart';

/// Local stand-in for Omi's conversations-v3 processing pipeline (Cloud Tasks
/// reconcile + `utils/conversations/v3/service.py`). When a conversation lands,
/// generate structured notes and extract memories in-process via the local LLM.
class ConversationPipeline {
  // Named params cannot be private fields in Dart; initialization list required.
  // ignore_for_file: prefer_initializing_formals
  ConversationPipeline({
    required ConversationStore conversations,
    required KnowledgeStore knowledge,
    required LlmSurface llm,
    EmbedSurface? embed,
  }) : _conversations = conversations,
       _knowledge = knowledge,
       _llm = llm,
       _embed = embed;

  // Constructor names stay unprefixed for call-site clarity; fields private.
  final ConversationStore _conversations;
  final KnowledgeStore _knowledge;
  final LlmSurface _llm;

  /// On-device embedding: every extracted memory gets a vector so semantic
  /// search finds it. Null (no local-embed card) leaves embeddings unset.
  final EmbedSurface? _embed;
  static const _uuid = Uuid();

  static const _notesPrompt = '''
你是一个对话记录助理。阅读下面的对话转写，输出严格的 JSON（不要任何解释文字）：
{"title": "不超过20字的标题", "overview": "两句话概述", "action_items": ["待办事项，可空"]}
只输出 JSON。''';

  static const _memoryPrompt = '''
从下面的对话转写中抽取值得长期记住的关于用户的稳定事实（偏好、人物关系、长期计划）。
输出严格的 JSON 数组：["事实1", "事实2"]。若没有，输出 []。只输出 JSON。''';

  /// Runs notes + memory extraction for one conversation. Idempotent: marks
  /// the conversation `completed` and writes `structured` notes back.
  Future<PipelineResult> process(String conversationId) async {
    final conv = _conversations.get(conversationId);
    if (conv == null) {
      return PipelineResult(conversationId: conversationId, processed: false);
    }
    final transcript = _transcriptText(conv);
    if (transcript.trim().isEmpty) {
      return PipelineResult(conversationId: conversationId, processed: false);
    }

    final notes = await _notes(transcript);
    _conversations.setStructured(conversationId, notes);

    final memories = await _memories(transcript, conversationId);
    final items = _actionItems(notes, conversationId);

    _conversations.upsert(
      Conversation(
        id: conv.id,
        startedAt: conv.startedAt,
        finishedAt: conv.finishedAt ?? DateTime.now(),
        status: 'completed',
        source: conv.source,
        language: conv.language,
        title: conv.title ?? notes['title'] as String?,
        visibility: conv.visibility,
        discarded: conv.discarded,
      ),
    );

    return PipelineResult(
      conversationId: conversationId,
      processed: true,
      memories: memories.length,
      actionItems: items.length,
    );
  }

  Future<Map<String, dynamic>> _notes(String transcript) async {
    try {
      final reply = await _llm.complete([
        {'role': 'system', 'content': _notesPrompt},
        {'role': 'user', 'content': transcript},
      ], temperature: 0.2);
      return _extractJsonObject(reply.content);
    } on LlmException {
      return {'title': null, 'overview': '', 'action_items': <String>[]};
    }
  }

  Future<List<Memory>> _memories(String transcript, String conversationId) async {
    List<String> facts;
    try {
      final reply = await _llm.complete([
        {'role': 'system', 'content': _memoryPrompt},
        {'role': 'user', 'content': transcript},
      ], temperature: 0.1);
      facts = _extractJsonArray(reply.content);
    } on LlmException {
      return const [];
    }
    final created = <Memory>[];
    // Batch-embed all facts at once — one engine pass, not N.
    final texts = [for (final f in facts) f.trim()].where((t) => t.isNotEmpty).toList();
    List<List<double>>? vectors;
    if (_embed != null && texts.isNotEmpty) {
      try {
        vectors = await _embed.embed(texts);
      } catch (_) {
        // embedding is an enhancement, never a blocker: store without vectors.
      }
    }
    for (var i = 0; i < texts.length; i++) {
      final m = Memory(
        id: _uuid.v4(),
        content: texts[i],
        category: 'interesting',
        createdAt: DateTime.now(),
        sourceConversationId: conversationId,
        embedding: vectors != null && i < vectors.length ? vectors[i] : null,
      );
      _knowledge.upsertMemory(m);
      created.add(m);
    }
    return created;
  }

  List<ActionItem> _actionItems(Map<String, dynamic> notes, String conversationId) {
    final raw = notes['action_items'];
    if (raw is! List) return const [];
    final created = <ActionItem>[];
    for (final item in raw) {
      final text = item.toString().trim();
      if (text.isEmpty) continue;
      final a = ActionItem(
        id: _uuid.v4(),
        description: text,
        createdAt: DateTime.now(),
        conversationId: conversationId,
        source: 'conversation',
      );
      _knowledge.upsertActionItem(a);
      created.add(a);
    }
    return created;
  }

  static String _transcriptText(Conversation c) =>
      (c.transcript ?? const []).map((s) => '${s.isUser ? '用户' : s.speaker}: ${s.text}').join('\n');

  /// Tolerates fenced code blocks and surrounding prose: takes the outermost
  /// `{...}`.
  static Map<String, dynamic> _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return {};
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  static List<String> _extractJsonArray(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      if (decoded is! List) return const [];
      return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }
}

class PipelineResult {
  PipelineResult({required this.conversationId, required this.processed, this.memories = 0, this.actionItems = 0});

  final String conversationId;
  final bool processed;
  final int memories;
  final int actionItems;
}
