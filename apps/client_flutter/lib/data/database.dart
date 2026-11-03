import 'package:sqlite3/sqlite3.dart';

import '../core/app_paths.dart';

/// 极薄的 SQLite 封装：负责连接、PRAGMA 与版本迁移。
///
/// 不使用 ORM/代码生成：schema 很小且固定，手写 SQL 只需一个文件，
/// 也避免了 build_runner 代码生成在 CI/首编时的额外失败面。
class AppDatabase {
  AppDatabase(this.raw);

  final Database raw;

  static const int schemaVersion = 1;

  factory AppDatabase.open(String path) {
    final db = AppDatabase(sqlite3.open(path));
    db._applyPragmas();
    db._backupBeforeMigration(path);
    db._migrate();
    return db;
  }

  /// 单元测试用：内存库。
  factory AppDatabase.inMemory() {
    final db = AppDatabase(sqlite3.openInMemory());
    db._applyPragmas();
    db._migrate();
    return db;
  }

  factory AppDatabase.openDefault() => AppDatabase.open(AppPaths.databaseFile);

  void _applyPragmas() {
    raw.execute('PRAGMA journal_mode = WAL');
    raw.execute('PRAGMA synchronous = NORMAL');
    raw.execute('PRAGMA foreign_keys = ON');
  }

  void _migrate() {
    final current =
        raw.select('PRAGMA user_version').first['user_version'] as int;
    if (current >= schemaVersion) return;
    raw.execute('BEGIN');
    try {
      if (current < 1) _createV1();
      raw.execute('PRAGMA user_version = $schemaVersion');
      raw.execute('COMMIT');
    } catch (error) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 升级 schema 前先落一份一致性快照（`VACUUM INTO`，含 WAL 里的内容）。
  ///
  /// 只在「库里已有旧版本数据」时触发；备份失败直接抛错 —— 宁可打不开，
  /// 也不要让用户的数据在没有备份的情况下被迁移写坏。
  void _backupBeforeMigration(String path) {
    final current =
        raw.select('PRAGMA user_version').first['user_version'] as int;
    if (current >= schemaVersion) return;
    // 全新空库（没有 entries 表）没什么可备份的，跳过。
    final hasSchema = raw
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'entries'",
        )
        .isNotEmpty;
    if (!hasSchema) return;
    final backup = '$path.v$current.bak';
    try {
      raw.execute("VACUUM INTO '${backup.replaceAll("'", "''")}'");
    } catch (error) {
      throw StateError('迁移前备份失败（$backup）：$error');
    }
  }

  void _createV1() {
    raw.execute('''
      CREATE TABLE IF NOT EXISTS entries (
        id         TEXT PRIMARY KEY,
        title      TEXT NOT NULL DEFAULT '',
        body_md    TEXT NOT NULL DEFAULT '',
        entry_date INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        rev        INTEGER NOT NULL DEFAULT 1,
        deleted_at INTEGER,
        pinned     INTEGER NOT NULL DEFAULT 0,
        device_id  TEXT NOT NULL DEFAULT ''
      )
    ''');
    raw.execute(
      'CREATE INDEX IF NOT EXISTS idx_entries_date ON entries(entry_date DESC)',
    );
    raw.execute(
      'CREATE INDEX IF NOT EXISTS idx_entries_deleted ON entries(deleted_at)',
    );

    raw.execute('''
      CREATE TABLE IF NOT EXISTS attachments (
        id         TEXT PRIMARY KEY,
        entry_id   TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        sha256     TEXT NOT NULL,
        filename   TEXT NOT NULL,
        mime       TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    raw.execute(
      'CREATE INDEX IF NOT EXISTS idx_attachments_entry ON attachments(entry_id)',
    );
    raw.execute(
      'CREATE INDEX IF NOT EXISTS idx_attachments_sha ON attachments(sha256)',
    );

    raw.execute('''
      CREATE TABLE IF NOT EXISTS tags (
        id   TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE
      )
    ''');
    raw.execute('''
      CREATE TABLE IF NOT EXISTS entry_tags (
        entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        tag_id   TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (entry_id, tag_id)
      )
    ''');
    raw.execute('''
      CREATE TABLE IF NOT EXISTS app_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  /// 关闭前把 WAL 合并回主库：迁移/备份时只需要复制一个 `mdiary.sqlite`。
  void checkpoint() {
    raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  void dispose() => raw.dispose();
}
