import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'chunker.dart';

/// RAG 索引库：`<库目录>/rag/index.sqlite`。
///
/// 与日记库分开，索引可以随时删掉重建；`rag/reports/` 与 `rag/soul.md` 是生成物，
/// 跟着库目录一起备份。
class RagDatabase {
  RagDatabase._(this.raw, this.path);

  final Database raw;
  final String path;

  static const int schemaVersion = 2;

  static RagDatabase open(String path) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final raw = sqlite3.open(path);
    raw.execute('PRAGMA journal_mode = WAL');
    raw.execute('PRAGMA synchronous = NORMAL');
    _migrate(raw);
    return RagDatabase._(raw, path);
  }

  static void _migrate(Database raw) {
    final current =
        (raw.select('PRAGMA user_version').first['user_version'] as int?) ?? 0;
    if (current >= schemaVersion) return;
    raw.execute('BEGIN');
    try {
      if (current < 1) {
        raw.execute('''
          CREATE TABLE IF NOT EXISTS chunk (
            id            TEXT PRIMARY KEY,
            kind          TEXT NOT NULL,
            entry_id      TEXT,
            attachment_id TEXT,
            ordinal       INTEGER NOT NULL DEFAULT 0,
            heading_path  TEXT NOT NULL DEFAULT '',
            label         TEXT NOT NULL DEFAULT '',
            source_date   INTEGER NOT NULL DEFAULT 0,
            text          TEXT NOT NULL,
            tokens        INTEGER NOT NULL DEFAULT 0,
            hash          TEXT NOT NULL,
            updated_at    INTEGER NOT NULL
          )
        ''');
        raw.execute(
          'CREATE INDEX IF NOT EXISTS idx_chunk_entry ON chunk(entry_id)',
        );
        raw.execute(
          'CREATE INDEX IF NOT EXISTS idx_chunk_attachment ON chunk(attachment_id)',
        );
        raw.execute('''
          CREATE TABLE IF NOT EXISTS chunk_vec (
            chunk_id TEXT PRIMARY KEY,
            dim      INTEGER NOT NULL,
            vector   BLOB NOT NULL
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS entry_index (
            entry_id     TEXT PRIMARY KEY,
            source_hash  TEXT NOT NULL,
            chunk_count  INTEGER NOT NULL,
            indexed_at   INTEGER NOT NULL
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS attachment_index (
            sha256       TEXT PRIMARY KEY,
            source_hash  TEXT NOT NULL,
            chunk_count  INTEGER NOT NULL,
            indexed_at   INTEGER NOT NULL
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS entry_summary (
            entry_id       TEXT PRIMARY KEY,
            summary        TEXT NOT NULL DEFAULT '',
            tags_suggested TEXT NOT NULL DEFAULT '',
            generated_at   INTEGER NOT NULL DEFAULT 0,
            model          TEXT NOT NULL DEFAULT ''
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS attachment_text (
            sha256     TEXT PRIMARY KEY,
            text       TEXT NOT NULL,
            source     TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS report (
            date         TEXT PRIMARY KEY,
            markdown     TEXT NOT NULL,
            model        TEXT NOT NULL DEFAULT '',
            generated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS index_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        raw.execute('''
          CREATE TABLE IF NOT EXISTS job (
            id          TEXT PRIMARY KEY,
            kind        TEXT NOT NULL,
            target_date TEXT NOT NULL DEFAULT '',
            status      TEXT NOT NULL DEFAULT 'pending',
            attempts    INTEGER NOT NULL DEFAULT 0,
            last_error  TEXT,
            updated_at  INTEGER NOT NULL DEFAULT 0
          )
        ''');
      }
      if (current < 2) {
        _ensureColumn(
          raw,
          'entry_summary',
          'source_hash',
          "TEXT NOT NULL DEFAULT ''",
        );
      }
      raw.execute('PRAGMA user_version = $schemaVersion');
      raw.execute('COMMIT');
    } catch (error) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// v2：给已有库补列（新库建表时也会跑到这里，幂等）。
  static void _ensureColumn(
    Database raw,
    String table,
    String column,
    String definition,
  ) {
    final columns = raw
        .select('PRAGMA table_info($table)')
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    if (columns.contains(column)) return;
    raw.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  // ─────────────────────────── 摘要（2.0.4） ───────────────────────────

  String? entrySummaryHash(String entryId) {
    final rows = raw.select(
      'SELECT source_hash FROM entry_summary WHERE entry_id = ?',
      <Object?>[entryId],
    );
    if (rows.isEmpty) return null;
    final hash = rows.first['source_hash'] as String? ?? '';
    return hash.isEmpty ? null : hash;
  }

  String? entrySummaryOf(String entryId) {
    final rows = raw.select(
      'SELECT summary FROM entry_summary WHERE entry_id = ?',
      <Object?>[entryId],
    );
    return rows.isEmpty ? null : rows.first['summary'] as String?;
  }

  List<String> suggestedTagsOf(String entryId) {
    final rows = raw.select(
      'SELECT tags_suggested FROM entry_summary WHERE entry_id = ?',
      <Object?>[entryId],
    );
    if (rows.isEmpty) return const <String>[];
    final rawJson = rows.first['tags_suggested'] as String? ?? '';
    if (rawJson.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is List) {
        return decoded.map((item) => '$item').toList(growable: false);
      }
    } on Object {
      // 坏数据当没有
    }
    return const <String>[];
  }

  void upsertEntrySummary({
    required String entryId,
    required String summary,
    required List<String> tags,
    required String sourceHash,
    required String model,
  }) {
    raw.execute(
      'INSERT INTO entry_summary '
      '(entry_id, summary, tags_suggested, generated_at, model, source_hash) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(entry_id) DO UPDATE SET summary = excluded.summary, '
      'tags_suggested = excluded.tags_suggested, '
      'generated_at = excluded.generated_at, model = excluded.model, '
      'source_hash = excluded.source_hash',
      <Object?>[
        entryId,
        summary,
        jsonEncode(tags),
        DateTime.now().millisecondsSinceEpoch,
        model,
        sourceHash,
      ],
    );
  }

  int summaryCount() =>
      (raw.select('SELECT COUNT(*) AS c FROM entry_summary').first['c'] as int?) ??
      0;

  // ─────────────────────────── 日报（2.0.5） ───────────────────────────

  String? reportOf(String date) {
    final rows = raw.select(
      'SELECT markdown FROM report WHERE date = ?',
      <Object?>[date],
    );
    return rows.isEmpty ? null : rows.first['markdown'] as String?;
  }

  String? reportModelOf(String date) {
    final rows = raw.select(
      'SELECT model FROM report WHERE date = ?',
      <Object?>[date],
    );
    return rows.isEmpty ? null : rows.first['model'] as String?;
  }

  void upsertReport({
    required String date,
    required String markdown,
    required String model,
  }) {
    raw.execute(
      'INSERT INTO report (date, markdown, model, generated_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(date) DO UPDATE SET markdown = excluded.markdown, '
      'model = excluded.model, generated_at = excluded.generated_at',
      <Object?>[
        date,
        markdown,
        model,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 已有日报的日期，最新在前。
  List<String> reportDates() {
    final rows = raw.select('SELECT date FROM report ORDER BY date DESC');
    return rows.map((row) => row['date']! as String).toList(growable: false);
  }

  int reportCount() =>
      (raw.select('SELECT COUNT(*) AS c FROM report').first['c'] as int?) ?? 0;
  // ─────────────────────────── 每日任务（2.0.4） ───────────────────────────

  Map<String, Object?>? job(String id) {
    final rows = raw.select('SELECT * FROM job WHERE id = ?', <Object?>[id]);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  void upsertJob({
    required String id,
    required String kind,
    required String targetDate,
    required String status,
    int attempts = 0,
    String? lastError,
  }) {
    raw.execute(
      'INSERT INTO job (id, kind, target_date, status, attempts, last_error, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET status = excluded.status, '
      'attempts = excluded.attempts, last_error = excluded.last_error, '
      'updated_at = excluded.updated_at',
      <Object?>[
        id,
        kind,
        targetDate,
        status,
        attempts,
        lastError,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }
  String? meta(String key) {
    final rows = raw.select(
      'SELECT value FROM index_meta WHERE key = ?',
      <Object?>[key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void setMeta(String key, String value) {
    raw.execute(
      'INSERT INTO index_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      <Object?>[key, value],
    );
  }

  int chunkCount() =>
      (raw.select('SELECT COUNT(*) AS c FROM chunk').first['c'] as int?) ?? 0;

  /// 该条目已索引的内容哈希；没索引过返回 null。
  String? entryHash(String entryId) {
    final rows = raw.select(
      'SELECT source_hash FROM entry_index WHERE entry_id = ?',
      <Object?>[entryId],
    );
    return rows.isEmpty ? null : rows.first['source_hash'] as String?;
  }

  void setEntryHash(String entryId, String hash, int chunkCount) {
    raw.execute(
      'INSERT INTO entry_index (entry_id, source_hash, chunk_count, indexed_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(entry_id) DO UPDATE SET source_hash = excluded.source_hash, '
      'chunk_count = excluded.chunk_count, indexed_at = excluded.indexed_at',
      <Object?>[
        entryId,
        hash,
        chunkCount,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  String? attachmentHash(String sha256) {
    final rows = raw.select(
      'SELECT source_hash FROM attachment_index WHERE sha256 = ?',
      <Object?>[sha256],
    );
    return rows.isEmpty ? null : rows.first['source_hash'] as String?;
  }

  void setAttachmentHash(String sha256, String hash, int chunkCount) {
    raw.execute(
      'INSERT INTO attachment_index (sha256, source_hash, chunk_count, indexed_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(sha256) DO UPDATE SET source_hash = excluded.source_hash, '
      'chunk_count = excluded.chunk_count, indexed_at = excluded.indexed_at',
      <Object?>[
        sha256,
        hash,
        chunkCount,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  String? attachmentText(String sha256) {
    final rows = raw.select(
      'SELECT text FROM attachment_text WHERE sha256 = ?',
      <Object?>[sha256],
    );
    return rows.isEmpty ? null : rows.first['text'] as String?;
  }

  void setAttachmentText(String sha256, String text, String source) {
    raw.execute(
      'INSERT INTO attachment_text (sha256, text, source, updated_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(sha256) DO UPDATE SET text = excluded.text, '
      'source = excluded.source, updated_at = excluded.updated_at',
      <Object?>[sha256, text, source, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void deleteChunksForEntry(String entryId) {
    raw.execute(
      'DELETE FROM chunk_vec WHERE chunk_id IN '
      '(SELECT id FROM chunk WHERE entry_id = ?)',
      <Object?>[entryId],
    );
    raw.execute('DELETE FROM chunk WHERE entry_id = ?', <Object?>[entryId]);
  }

  void deleteChunksForAttachment(String attachmentId) {
    raw.execute(
      'DELETE FROM chunk_vec WHERE chunk_id IN '
      '(SELECT id FROM chunk WHERE attachment_id = ?)',
      <Object?>[attachmentId],
    );
    raw.execute('DELETE FROM chunk WHERE attachment_id = ?', <Object?>[
      attachmentId,
    ]);
  }

  /// 写入一批切片与向量（同一事务）。
  void insertChunks(List<RagChunk> chunks, List<List<double>> vectors) {
    if (chunks.length != vectors.length) {
      throw ArgumentError('切片数与向量数不一致');
    }
    if (chunks.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    raw.execute('BEGIN');
    try {
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final vector = vectors[i];
        final id = '${chunk.entryId ?? chunk.attachmentId}-${chunk.ordinal}-${chunk.hash.substring(0, 12)}';
        raw.execute(
          'INSERT OR REPLACE INTO chunk '
          '(id, kind, entry_id, attachment_id, ordinal, heading_path, label, source_date, text, tokens, hash, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            id,
            chunk.kind,
            chunk.entryId,
            chunk.attachmentId,
            chunk.ordinal,
            chunk.headingPath,
            chunk.label,
            chunk.sourceDate.millisecondsSinceEpoch,
            chunk.text,
            chunk.tokens,
            chunk.hash,
            now,
          ],
        );
        final floats = Float32List.fromList(vector);
        raw.execute(
          'INSERT OR REPLACE INTO chunk_vec (chunk_id, dim, vector) VALUES (?, ?, ?)',
          <Object?>[
            id,
            vector.length,
            floats.buffer.asUint8List(
              floats.offsetInBytes,
              floats.lengthInBytes,
            ),
          ],
        );
      }
      raw.execute('COMMIT');
    } catch (error) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 读出所有切片与向量（暴力 KNN 用；几万条以内够快）。
  List<ChunkWithVector> chunksWithVectors() {
    final rows = raw.select(
      'SELECT c.id, c.kind, c.entry_id, c.attachment_id, c.ordinal, '
      'c.heading_path, c.label, c.source_date, c.text, c.tokens, v.vector '
      'FROM chunk c JOIN chunk_vec v ON v.chunk_id = c.id',
    );
    final result = <ChunkWithVector>[];
    for (final row in rows) {
      final blob = row['vector'] as Uint8List;
      final copy = Uint8List.fromList(blob);
      result.add(
        ChunkWithVector(
          id: row['id']! as String,
          kind: row['kind']! as String,
          entryId: row['entry_id'] as String?,
          attachmentId: row['attachment_id'] as String?,
          ordinal: row['ordinal']! as int,
          headingPath: row['heading_path']! as String,
          label: row['label']! as String,
          sourceDate: DateTime.fromMillisecondsSinceEpoch(
            row['source_date']! as int,
          ),
          text: row['text']! as String,
          tokens: row['tokens']! as int,
          vector: Float32List.view(copy.buffer),
        ),
      );
    }
    return result;
  }

  /// 删掉所有切片与增量记录（换 embedding 模型时用）。
  void clearIndex() {
    raw.execute('BEGIN');
    try {
      raw.execute('DELETE FROM chunk_vec');
      raw.execute('DELETE FROM chunk');
      raw.execute('DELETE FROM entry_index');
      raw.execute('DELETE FROM attachment_index');
      raw.execute('COMMIT');
    } catch (error) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => raw.dispose();
}

class ChunkWithVector {
  ChunkWithVector({
    required this.id,
    required this.kind,
    required this.entryId,
    required this.attachmentId,
    required this.ordinal,
    required this.headingPath,
    required this.label,
    required this.sourceDate,
    required this.text,
    required this.tokens,
    required this.vector,
  });

  final String id;
  final String kind;
  final String? entryId;
  final String? attachmentId;
  final int ordinal;
  final String headingPath;
  final String label;
  final DateTime sourceDate;
  final String text;
  final int tokens;
  final Float32List vector;
}
