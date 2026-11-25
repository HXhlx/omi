import 'package:sqlite3/sqlite3.dart';

/// Single-user local store. Mirrors the Omi Postgres/Firestore shape into one
/// SQLite file. Vector search is cosine over locally-stored embedding JSON
/// (replaces Pinecone/Typesense); keyword search is FTS-free LIKE.
class LocalDb {
  LocalDb(this._db);

  factory LocalDb.open(String path) => LocalDb(sqlite3.open(path));

  /// In-memory store for tests.
  factory LocalDb.inMemory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys = ON');
    return LocalDb(db);
  }

  final Database _db;

  static const _schema = '''
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT
    );
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY,
      started_at TEXT,
      finished_at TEXT,
      status TEXT,
      source TEXT,
      language TEXT,
      title TEXT,
      visibility TEXT DEFAULT 'private',
      transcript_mode TEXT,
      structured TEXT,
      discarded INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS transcript_segments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT,
      text TEXT,
      start REAL,
      end REAL,
      speaker TEXT
    );
    CREATE TABLE IF NOT EXISTS chat_messages (
      id TEXT PRIMARY KEY,
      role TEXT,
      text TEXT,
      created_at TEXT
    );
    CREATE TABLE IF NOT EXISTS memories (
      id TEXT PRIMARY KEY,
      content TEXT,
      kind TEXT,
      source_conversation_id TEXT,
      created_at TEXT,
      embedding TEXT,
      visibility TEXT DEFAULT 'private',
      is_read INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS action_items (
      id TEXT PRIMARY KEY,
      text TEXT,
      status TEXT,
      created_at TEXT,
      due_at TEXT,
      source TEXT,
      conversation_id TEXT
    );
    CREATE TABLE IF NOT EXISTS goals (
      id TEXT PRIMARY KEY,
      title TEXT,
      status TEXT,
      desired_outcome TEXT,
      created_at TEXT,
      updated_at TEXT
    );
    CREATE TABLE IF NOT EXISTS people (
      id TEXT PRIMARY KEY,
      name TEXT,
      created_at TEXT
    );
    CREATE TABLE IF NOT EXISTS daily_summaries (
      id TEXT PRIMARY KEY,
      date TEXT,
      content TEXT,
      created_at TEXT
    );
    CREATE TABLE IF NOT EXISTS folders (
      id TEXT PRIMARY KEY,
      name TEXT,
      color TEXT,
      description TEXT,
      icon TEXT,
      created_at TEXT,
      updated_at TEXT
    );
    CREATE TABLE IF NOT EXISTS voice_prefs (
      key TEXT PRIMARY KEY,
      value TEXT
    );
    CREATE TABLE IF NOT EXISTS apps (
      id TEXT PRIMARY KEY,
      name TEXT,
      description TEXT,
      enabled INTEGER DEFAULT 0,
      created_at TEXT
    );
    CREATE TABLE IF NOT EXISTS wal_frames (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pcm BLOB,
      sample_rate INTEGER DEFAULT 16000,
      synced INTEGER DEFAULT 0,
      created_at TEXT
    );
    CREATE TABLE IF NOT EXISTS sync_ledger (
      id TEXT PRIMARY KEY,
      kind TEXT,
      created_at TEXT,
      payload TEXT
    );
  ''';

  Future<void> migrate() async {
    _db.execute(_schema);
  }

  void close() => _db.dispose();

  Database get db => _db;

  // ---- settings ----
  void setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  String? getSetting(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }
}