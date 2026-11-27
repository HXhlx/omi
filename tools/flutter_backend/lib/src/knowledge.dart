import 'dart:convert';
import 'dart:math' show sqrt;

import 'package:sqlite3/sqlite3.dart' show Row;

import 'db.dart';

/// Memory row — subset of the `MemoryDB` wire shape both clients read
/// (desktop `GET /v3/memories`, `POST /v3/memories`; Siri recall).
class Memory {
  Memory({
    required this.id,
    required this.content,
    this.category = 'interesting',
    this.kind,
    this.createdAt,
    this.sourceConversationId,
    this.embedding,
  });

  factory Memory.fromJson(Map<String, dynamic> j) => Memory(
        id: j['id'] as String,
        content: j['content'] as String? ?? '',
        category: j['category'] as String? ?? 'interesting',
        kind: j['kind'] as String?,
        createdAt: j['created_at'] == null
            ? null
            : DateTime.tryParse(j['created_at'] as String),
        sourceConversationId: j['source_conversation_id'] as String?,
      );

  final String id;
  final String content;
  final String category;
  final String? kind;
  final DateTime? createdAt;
  final String? sourceConversationId;
  final List<double>? embedding;

  Map<String, dynamic> toWire() => {
        'id': id,
        'content': content,
        'category': category,
        if (kind != null) 'kind': kind,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
        'is_edited': false,
        'visibility': 'private',
      };
}

/// Action item — `ActionItemResponse` subset.
class ActionItem {
  ActionItem({
    required this.id,
    required this.description,
    this.completed = false,
    this.createdAt,
    this.completedAt,
    this.conversationId,
    this.dueAt,
    this.source,
  });

  factory ActionItem.fromJson(Map<String, dynamic> j) => ActionItem(
        id: j['id'] as String,
        description: j['description'] as String? ?? j['text'] as String? ?? '',
        completed: j['completed'] as bool? ?? false,
        createdAt: j['created_at'] == null
            ? null
            : DateTime.tryParse(j['created_at'] as String),
        completedAt: j['completed_at'] == null
            ? null
            : DateTime.tryParse(j['completed_at'] as String),
        conversationId: j['conversation_id'] as String?,
        dueAt: j['due_at'] == null ? null : DateTime.tryParse(j['due_at'] as String),
        source: j['source'] as String?,
      );

  final String id;
  final String description;
  final bool completed;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final String? conversationId;
  final DateTime? dueAt;
  final String? source;

  Map<String, dynamic> toWire() => {
        'id': id,
        'description': description,
        'completed': completed,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
        if (conversationId != null) 'conversation_id': conversationId,
        if (dueAt != null) 'due_at': dueAt!.toIso8601String(),
        'status': completed ? 'completed' : 'pending',
      };
}

/// Persistence for memories + action items over [LocalDb].
class KnowledgeStore {
  KnowledgeStore(this._db);

  final LocalDb _db;

  // ---- memories ----
  void upsertMemory(Memory m) {
    _db.db.execute(
      'INSERT INTO memories (id, content, kind, source_conversation_id, created_at, embedding) '
      'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'content=excluded.content, kind=excluded.kind',
      [
        m.id,
        m.content,
        m.category,
        m.sourceConversationId,
        (m.createdAt ?? DateTime.now()).toIso8601String(),
        m.embedding == null ? null : jsonEncode(m.embedding),
      ],
    );
  }

  List<Memory> listMemories({int limit = 50, int offset = 0}) {
    final rows = _db.db.select(
        'SELECT * FROM memories ORDER BY created_at DESC LIMIT ? OFFSET ?',
        [limit, offset]);
    return rows.map<Memory>(_memoryFromRow).toList();
  }

  Memory? getMemory(String id) {
    final rows = _db.db.select('SELECT * FROM memories WHERE id = ?', [id]);
    return rows.isEmpty ? null : _memoryFromRow(rows.first);
  }

  void deleteMemory(String id) =>
      _db.db.execute('DELETE FROM memories WHERE id = ?', [id]);

  void clearMemories() => _db.db.execute('DELETE FROM memories');

  List<Memory> searchMemories(String query, {int limit = 10}) {
    final like = '%$query%';
    final rows = _db.db.select(
        'SELECT * FROM memories WHERE content LIKE ? ORDER BY created_at DESC LIMIT ?',
        [like, limit]);
    return rows.map<Memory>(_memoryFromRow).toList();
  }

  /// Cosine-ranked semantic search over stored embeddings. Memories without
  /// an embedding (created before the on-device embed engine was installed)
  /// are skipped. Null when no stored memory has a vector — callers then
  /// fall back to [searchMemories].
  List<Memory>? searchMemoriesVector(List<double> queryVector, {int limit = 10}) {
    final rows = _db.db.select('SELECT * FROM memories WHERE embedding IS NOT NULL');
    if (rows.isEmpty) return null;
    final query = _normalize(queryVector);
    if (query == null) return null;
    final scored = <(double, Memory)>[];
    for (final r in rows) {
      final m = _memoryFromRow(r);
      final v = m.embedding;
      if (v == null || v.length != query.length) continue;
      final nv = _normalize(v);
      if (nv == null) continue;
      var dot = 0.0;
      for (var i = 0; i < nv.length; i++) {
        dot += nv[i] * query[i];
      }
      scored.add((dot, m));
    }
    if (scored.isEmpty) return null;
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(limit).map((e) => e.$2).toList();
  }

  static List<double>? _normalize(List<double> v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm <= 0) return null;
    final inv = 1.0 / sqrt(norm);
    return [for (final x in v) x * inv];
  }

  Memory _memoryFromRow(Row r) => Memory(
        id: r['id'] as String,
        content: r['content'] as String,
        category: r['kind'] as String? ?? 'interesting',
        createdAt: r['created_at'] == null
            ? null
            : DateTime.tryParse(r['created_at'] as String),
        sourceConversationId: r['source_conversation_id'] as String?,
        embedding: _decodeEmbedding(r['embedding'] as String?),
      );

  static List<double>? _decodeEmbedding(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [for (final x in decoded) (x as num).toDouble()];
    } catch (_) {
      return null;
    }
  }

  // ---- action items ----
  void upsertActionItem(ActionItem a) {
    _db.db.execute(
      'INSERT INTO action_items (id, text, status, created_at, due_at, source, conversation_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'text=excluded.text, status=excluded.status, due_at=excluded.due_at, '
      'conversation_id=excluded.conversation_id',
      [
        a.id,
        a.description,
        a.completed ? 'completed' : 'pending',
        (a.createdAt ?? DateTime.now()).toIso8601String(),
        a.dueAt?.toIso8601String(),
        a.source,
        a.conversationId,
      ],
    );
  }

  List<ActionItem> listActionItems({int limit = 50, int offset = 0}) {
    final rows = _db.db.select(
        'SELECT * FROM action_items ORDER BY created_at DESC LIMIT ? OFFSET ?',
        [limit, offset]);
    return rows.map<ActionItem>(_actionItemFromRow).toList();
  }

  ActionItem? getActionItem(String id) {
    final rows = _db.db.select('SELECT * FROM action_items WHERE id = ?', [id]);
    return rows.isEmpty ? null : _actionItemFromRow(rows.first);
  }

  void deleteActionItem(String id) =>
      _db.db.execute('DELETE FROM action_items WHERE id = ?', [id]);

  ActionItem _actionItemFromRow(Row r) => ActionItem(
        id: r['id'] as String,
        description: r['text'] as String,
        completed: (r['status'] as String? ?? 'pending') == 'completed',
        createdAt: r['created_at'] == null
            ? null
            : DateTime.tryParse(r['created_at'] as String),
        dueAt: r['due_at'] == null ? null : DateTime.tryParse(r['due_at'] as String),
        conversationId: r['conversation_id'] as String?,
        source: r['source'] as String?,
      );
}