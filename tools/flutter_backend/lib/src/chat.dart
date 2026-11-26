import 'dart:convert';

import 'db.dart';

/// Chat message row + the wire shape both clients read (`Message`).
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.chatSessionId,
  });

  final String id;
  final String role; // 'user' | 'ai'
  final String text;
  final DateTime createdAt;
  final String? chatSessionId;

  Map<String, dynamic> toWire() => {
        'id': id,
        'text': text,
        'sender': role,
        'created_at': createdAt.toIso8601String(),
        'type': 'text',
        if (chatSessionId != null) 'chat_session_id': chatSessionId,
        'content_blocks': [
          {'type': 'text', 'text': text},
        ],
      };
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.createdAt,
    this.title,
    this.appId,
    this.starred = false,
    this.preview,
  });

  final String id;
  final DateTime createdAt;
  final String? title;
  final String? appId;
  final bool starred;
  final String? preview;

  Map<String, dynamic> toWire() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        if (title != null) 'title': title,
        if (appId != null) 'app_id': appId,
        'starred': starred,
        if (preview != null) 'preview': preview,
      };
}

/// Chat persistence. `chat_messages` predates sessions, so it gains a
/// `chat_session_id` column lazily on first use here.
class ChatStore {
  ChatStore(this._db) {
    _ensureSessionColumns();
  }

  final LocalDb _db;

  void _ensureSessionColumns() {
    _db.db.execute(
        'CREATE TABLE IF NOT EXISTS chat_sessions (id TEXT PRIMARY KEY, '
        'created_at TEXT, title TEXT, app_id TEXT, starred INTEGER DEFAULT 0, '
        'preview TEXT)');
    final cols = _db.db
        .select('PRAGMA table_info(chat_messages)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains('chat_session_id')) {
      _db.db.execute('ALTER TABLE chat_messages ADD COLUMN chat_session_id TEXT');
    }
  }

  // ---- sessions ----
  void upsertSession(ChatSession s) {
    _db.db.execute(
      'INSERT INTO chat_sessions (id, created_at, title, app_id, starred, preview) '
      'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'title=excluded.title, starred=excluded.starred, preview=excluded.preview',
      [s.id, s.createdAt.toIso8601String(), s.title, s.appId, s.starred ? 1 : 0, s.preview],
    );
  }

  ChatSession? getSession(String id) {
    final rows = _db.db.select('SELECT * FROM chat_sessions WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ChatSession(
      id: r['id'] as String,
      createdAt: DateTime.parse(r['created_at'] as String),
      title: r['title'] as String?,
      appId: r['app_id'] as String?,
      starred: (r['starred'] as int? ?? 0) == 1,
      preview: r['preview'] as String?,
    );
  }

  List<ChatSession> listSessions({int limit = 50, int offset = 0}) {
    final rows = _db.db.select(
        'SELECT * FROM chat_sessions ORDER BY created_at DESC LIMIT ? OFFSET ?',
        [limit, offset]);
    return rows
        .map((r) => ChatSession(
              id: r['id'] as String,
              createdAt: DateTime.parse(r['created_at'] as String),
              title: r['title'] as String?,
              appId: r['app_id'] as String?,
              starred: (r['starred'] as int? ?? 0) == 1,
              preview: r['preview'] as String?,
            ))
        .toList();
  }

  void deleteSession(String id) {
    _db.db.execute('DELETE FROM chat_sessions WHERE id = ?', [id]);
    _db.db.execute('DELETE FROM chat_messages WHERE chat_session_id = ?', [id]);
  }

  // ---- messages ----
  void insertMessage(ChatMessage m) {
    _db.db.execute(
      'INSERT INTO chat_messages (id, role, text, created_at, chat_session_id) '
      'VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET text=excluded.text',
      [m.id, m.role, m.text, m.createdAt.toIso8601String(), m.chatSessionId],
    );
  }

  List<ChatMessage> messages({String? chatSessionId, int limit = 50, int offset = 0}) {
    final where = <String>[];
    final args = <Object?>[];
    if (chatSessionId != null) {
      where.add('chat_session_id = ?');
      args.add(chatSessionId);
    }
    final sql = 'SELECT * FROM chat_messages'
        '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
        ' ORDER BY created_at ASC LIMIT ? OFFSET ?';
    args..add(limit)..add(offset);
    final rows = _db.db.select(sql, args);
    return rows
        .map((r) => ChatMessage(
              id: r['id'] as String,
              role: r['role'] as String,
              text: r['text'] as String,
              createdAt: DateTime.parse(r['created_at'] as String),
              chatSessionId: r['chat_session_id'] as String?,
            ))
        .toList();
  }

  void clearMessages({String? chatSessionId}) {
    if (chatSessionId == null) {
      _db.db.execute('DELETE FROM chat_messages');
    } else {
      _db.db.execute('DELETE FROM chat_messages WHERE chat_session_id = ?', [chatSessionId]);
    }
  }

  /// Prior turns as role/content pairs for the LLM context window.
  List<Map<String, String>> contextMessages({String? chatSessionId, int limit = 20}) =>
      messages(chatSessionId: chatSessionId, limit: limit)
          .map((m) => {
                'role': m.role == 'ai' ? 'assistant' : 'user',
                'content': m.text,
              })
          .toList();

  String toBase64Json(Map<String, dynamic> m) =>
      base64Encode(utf8.encode(jsonEncode(m)));
}