import 'dart:convert';

import 'db.dart';

/// User-scoped records: profile, people, goals, folders, daily summaries.
/// Backed by SQLite; profile/ai-profile live in the `settings` key/value store.
class UserStore {
  UserStore(this._db);

  final LocalDb _db;

  // ---- profile ----
  Map<String, dynamic> profile() {
    final raw = _db.getSetting('user_profile');
    final stored = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    return {
      'uid': 'local-dev-user',
      'name': stored['name'] ?? '小蜗用户',
      'email': '',
      'company': stored['company'] ?? '',
      'job': stored['job'] ?? '',
      'motivation': stored['motivation'] ?? '',
      'use_case': stored['use_case'] ?? '',
      'time_zone': stored['time_zone'] ?? 'Asia/Shanghai',
      'created_at': stored['created_at'] ?? DateTime.now().toIso8601String(),
      'data_protection_level': 'local',
      'migration_status': <String, dynamic>{},
    };
  }

  Map<String, dynamic> updateProfile(Map<String, dynamic> patch) {
    final raw = _db.getSetting('user_profile');
    final stored = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    stored.addAll(patch);
    _db.setSetting('user_profile', jsonEncode(stored));
    return profile();
  }

  // ---- ai profile ----
  Map<String, dynamic> aiProfile() {
    final raw = _db.getSetting('ai_profile');
    return raw == null ? {'profile_text': '', 'version': 0} : jsonDecode(raw) as Map<String, dynamic>;
  }

  Map<String, dynamic> setAiProfile(Map<String, dynamic> body) {
    final next = {
      'profile_text': body['profile_text'] as String? ?? body['text'] as String? ?? '',
      'version': (aiProfile()['version'] as int? ?? 0) + 1,
      'updated_at': DateTime.now().toIso8601String(),
    };
    _db.setSetting('ai_profile', jsonEncode(next));
    return next;
  }

  void deleteAiProfile() => _db.setSetting('ai_profile', jsonEncode(<String, dynamic>{}));

  // ---- people ----
  void upsertPerson(String id, String name) {
    _db.db.execute(
      'INSERT INTO people (id, name, created_at) VALUES (?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET name=excluded.name',
      [id, name, DateTime.now().toIso8601String()],
    );
  }

  List<Map<String, dynamic>> listPeople() => _db.db
      .select('SELECT * FROM people ORDER BY created_at DESC')
      .map<Map<String, dynamic>>((r) => {
            'id': r['id'],
            'name': r['name'],
            'created_at': r['created_at'],
            'conversation_count': 0,
            'confidence': 'unknown',
          })
      .toList();

  void deletePerson(String id) => _db.db.execute('DELETE FROM people WHERE id = ?', [id]);

  // ---- goals ----
  void upsertGoal(Map<String, dynamic> g) {
    final now = DateTime.now().toIso8601String();
    _db.db.execute(
      'INSERT INTO goals (id, title, status, desired_outcome, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'title=excluded.title, status=excluded.status, '
      'desired_outcome=excluded.desired_outcome, updated_at=excluded.updated_at',
      [
        g['id'],
        g['title'],
        g['status'] ?? 'active',
        g['desired_outcome'] ?? '',
        (g['created_at'] as String?) ?? now,
        now,
      ],
    );
  }

  Map<String, dynamic> _goalFromRow(Map<String, Object?> r) => {
        'id': r['id'],
        'goal_id': r['id'],
        'title': r['title'],
        'desired_outcome': r['desired_outcome'] ?? '',
        'status': r['status'] ?? 'active',
        'source': 'user',
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
        'goal_type': 'goal',
        'target_value': 1,
        'current_value': 0,
        'min_value': 0,
        'max_value': 1,
        'is_active': (r['status'] ?? 'active') == 'active',
        'success_criteria': <Object>[],
        'unit': '',
      };

  Map<String, dynamic>? getGoal(String id) {
    final rows = _db.db.select('SELECT * FROM goals WHERE id = ?', [id]);
    return rows.isEmpty ? null : _goalFromRow(rows.first);
  }

  /// `GET /v1/goals` returns the single current goal upstream.
  Map<String, dynamic>? currentGoal() {
    final rows = _db.db.select(
        "SELECT * FROM goals WHERE status = 'active' ORDER BY created_at DESC LIMIT 1");
    return rows.isEmpty ? null : _goalFromRow(rows.first);
  }

  List<Map<String, dynamic>> listGoals() =>
      _db.db.select('SELECT * FROM goals ORDER BY created_at DESC').map<Map<String, dynamic>>(
          (r) => _goalFromRow(r)).toList();

  void deleteGoal(String id) => _db.db.execute('DELETE FROM goals WHERE id = ?', [id]);

  // ---- folders ----
  void upsertFolder(Map<String, dynamic> f) {
    final now = DateTime.now().toIso8601String();
    _db.db.execute(
      'INSERT INTO folders (id, name, color, description, icon, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'name=excluded.name, color=excluded.color, description=excluded.description, '
      'icon=excluded.icon, updated_at=excluded.updated_at',
      [
        f['id'],
        f['name'],
        f['color'] ?? '#6B7280',
        f['description'] ?? '',
        f['icon'] ?? '',
        (f['created_at'] as String?) ?? now,
        now,
      ],
    );
  }

  Map<String, dynamic> _folderFromRow(Map<String, Object?> r) => {
        'id': r['id'],
        'name': r['name'],
        'color': r['color'] ?? '#6B7280',
        'description': r['description'] ?? '',
        'icon': r['icon'] ?? '',
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
        'conversation_count': 0,
        'is_default': false,
        'is_system': false,
        'order': 0,
      };

  List<Map<String, dynamic>> listFolders() => _db.db
      .select('SELECT * FROM folders ORDER BY created_at ASC')
      .map<Map<String, dynamic>>((r) => _folderFromRow(r))
      .toList();

  Map<String, dynamic>? getFolder(String id) {
    final rows = _db.db.select('SELECT * FROM folders WHERE id = ?', [id]);
    return rows.isEmpty ? null : _folderFromRow(rows.first);
  }

  void deleteFolder(String id) => _db.db.execute('DELETE FROM folders WHERE id = ?', [id]);

  // ---- daily summaries ----
  void upsertDailySummary(Map<String, dynamic> s) {
    _db.db.execute(
      'INSERT INTO daily_summaries (id, date, content, created_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET content=excluded.content, date=excluded.date',
      [
        s['id'],
        s['date'],
        jsonEncode(s),
        (s['created_at'] as String?) ?? DateTime.now().toIso8601String(),
      ],
    );
  }

  List<Map<String, dynamic>> listDailySummaries({int limit = 30, int offset = 0}) => _db.db
      .select('SELECT content FROM daily_summaries ORDER BY date DESC LIMIT ? OFFSET ?',
          [limit, offset])
      .map<Map<String, dynamic>>(
          (r) => jsonDecode(r['content'] as String) as Map<String, dynamic>)
      .toList();

  /// Built when a summary for [date] is requested but absent: derived from the
  /// conversations captured that day, so the client always has a payload.
  Map<String, dynamic> buildDailySummary(String date) {
    final rows = _db.db.select(
        'SELECT id, title, started_at FROM conversations WHERE started_at LIKE ? '
        'ORDER BY started_at ASC',
        ['$date%']);
    final titles = rows
        .map((r) => r['title'] as String? ?? '未命名对话')
        .where((t) => t.isNotEmpty)
        .toList();
    return {
      'id': 'summary-$date',
      'date': date,
      'headline': titles.isEmpty ? '这一天没有记录' : '${titles.length} 段对话',
      'overview': titles.isEmpty ? '' : titles.join('；'),
      'day_emoji': '📝',
      'highlights': titles,
      'action_items': <Object>[],
      'decisions_made': <Object>[],
      'knowledge_nuggets': <Object>[],
      'locations': <Object>[],
      'memories_learned': <Object>[],
      'unresolved_questions': <Object>[],
      'created_at': DateTime.now().toIso8601String(),
    };
  }

  /// Local build: all cloud feature flags are off; returns an empty map so the
  /// client falls back to its default behavior everywhere.
  Map<String, dynamic> flags() => {'flags': <String, dynamic>{}};
}