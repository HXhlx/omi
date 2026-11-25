import 'dart:convert';

import 'conversation.dart';
import 'db.dart';

/// Conversation persistence over [LocalDb]. Wire keys map to columns; the
/// `structured` column stays opaque JSON (notes/action-item payload).
class ConversationStore {
  ConversationStore(this._db);

  final LocalDb _db;

  void upsert(Conversation c) {
    _db.db.execute(
      'INSERT INTO conversations (id, started_at, finished_at, status, source, '
      'language, title, visibility, structured, discarded) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET started_at=excluded.started_at, '
      'finished_at=excluded.finished_at, status=excluded.status, '
      'source=excluded.source, language=excluded.language, title=excluded.title, '
      'visibility=excluded.visibility, structured=excluded.structured, '
      'discarded=excluded.discarded',
      [
        c.id,
        c.startedAt.toIso8601String(),
        c.finishedAt?.toIso8601String(),
        c.status,
        c.source,
        c.language,
        c.title,
        c.visibility,
        null,
        c.discarded ? 1 : 0,
      ],
    );
  }

  void replaceSegments(String conversationId, List<TranscriptSegment> segs) {
    _db.db.execute(
      'DELETE FROM transcript_segments WHERE conversation_id = ?',
      [conversationId],
    );
    for (final s in segs) {
      _db.db.execute(
        'INSERT INTO transcript_segments (conversation_id, text, start, end, speaker) '
        'VALUES (?, ?, ?, ?, ?)',
        [conversationId, s.text, s.start, s.end, s.speaker],
      );
    }
  }

  List<TranscriptSegment> segments(String conversationId) {
    final rows = _db.db.select(
      'SELECT text, start, end, speaker FROM transcript_segments '
      'WHERE conversation_id = ? ORDER BY start ASC',
      [conversationId],
    );
    return rows
        .map((r) => TranscriptSegment(
              text: r['text'] as String,
              isUser: _isUserSpeaker(r['speaker'] as String?),
              start: (r['start'] as num).toDouble(),
              end: (r['end'] as num).toDouble(),
              speaker: r['speaker'] as String? ?? 'SPEAKER_00',
            ))
        .toList();
  }

  /// Omi encodes the user's own speech as speaker `SPEAKER_00` by default and
  /// flags it with `is_user`; the local build keeps that convention.
  static bool _isUserSpeaker(String? speaker) => speaker == null || speaker == 'SPEAKER_00';

  Conversation? get(String id) {
    final rows = _db.db.select('SELECT * FROM conversations WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Conversation(
      id: r['id'] as String,
      startedAt: DateTime.parse(r['started_at'] as String),
      finishedAt: r['finished_at'] == null
          ? null
          : DateTime.parse(r['finished_at'] as String),
      status: r['status'] as String? ?? 'processing',
      source: r['source'] as String? ?? 'desktop',
      language: r['language'] as String? ?? 'zh',
      title: r['title'] as String?,
      visibility: r['visibility'] as String? ?? 'private',
      discarded: (r['discarded'] as int? ?? 0) == 1,
      transcript: segments(id),
    );
  }

  List<Conversation> list({int limit = 50, int offset = 0}) {
    final rows = _db.db.select(
      'SELECT * FROM conversations ORDER BY started_at DESC LIMIT ? OFFSET ?',
      [limit, offset],
    );
    return rows.map((r) {
      final c = Conversation(
        id: r['id'] as String,
        startedAt: DateTime.parse(r['started_at'] as String),
        finishedAt: r['finished_at'] == null
            ? null
            : DateTime.parse(r['finished_at'] as String),
        status: r['status'] as String? ?? 'processing',
        source: r['source'] as String? ?? 'desktop',
        language: r['language'] as String? ?? 'zh',
        title: r['title'] as String?,
        visibility: r['visibility'] as String? ?? 'private',
        discarded: (r['discarded'] as int? ?? 0) == 1,
      );
      return c;
    }).toList();
  }

  int count() => _db.db.select('SELECT COUNT(*) AS n FROM conversations').first['n'] as int;

  void delete(String id, {bool cascade = false}) {
    _db.db.execute('DELETE FROM conversations WHERE id = ?', [id]);
    _db.db.execute('DELETE FROM transcript_segments WHERE conversation_id = ?', [id]);
    if (cascade) {
      _db.db.execute('DELETE FROM action_items WHERE conversation_id = ?', [id]);
    }
  }

  /// Serialise a conversation with its transcript for API responses.
  Map<String, dynamic> toWire(String id) {
    final c = get(id);
    if (c == null) throw StateError('missing conversation $id');
    return c.toJson();
  }

  /// JSON body form used in `structured`-driven notes; kept for the pipeline
  /// step, which writes notes back into this column.
  void setStructured(String id, Object payload) {
    _db.db.execute(
      'UPDATE conversations SET structured = ? WHERE id = ?',
      [jsonEncode(payload), id],
    );
  }
}