import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../core/ids.dart';
import 'attachment_store.dart' show normalizeExtension;
import 'database.dart';
import 'models.dart';

class AttachmentRepository {
  AttachmentRepository(this._db);

  final AppDatabase _db;

  Database get _raw => _db.raw;

  List<Attachment> listByEntry(String entryId) {
    final rows = _raw.select(
      'SELECT * FROM attachments WHERE entry_id = ? ORDER BY created_at ASC',
      <Object?>[entryId],
    );
    return rows
        .map((row) => Attachment.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  Attachment insert({
    required String entryId,
    required String sha256,
    required String filename,
    required String mime,
    required int sizeBytes,
  }) {
    final attachment = Attachment(
      id: newId(),
      entryId: entryId,
      sha256: sha256,
      filename: filename,
      mime: mime,
      sizeBytes: sizeBytes,
      createdAt: DateTime.now(),
    );
    _raw.execute(
      'INSERT INTO attachments (id, entry_id, sha256, filename, mime, size_bytes, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        attachment.id,
        attachment.entryId,
        attachment.sha256,
        attachment.filename,
        attachment.mime,
        attachment.sizeBytes,
        attachment.createdAt.millisecondsSinceEpoch,
      ],
    );
    return attachment;
  }

  Attachment? findById(String id) {
    final rows = _raw.select(
      'SELECT * FROM attachments WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return Attachment.fromMap(Map<String, Object?>.from(rows.first));
  }

  /// 全库附件（星图用：一次拿到所有「日记 -> 附件」索引关系）。
  List<Attachment> all() {
    final rows = _raw.select(
      'SELECT * FROM attachments ORDER BY created_at ASC',
    );
    return rows
        .map((row) => Attachment.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  /// 每个条目的附件数（列表页角标一次查完，避免按行 N 次查询）。
  Map<String, int> countsByEntry() {    final rows = _raw.select(
      'SELECT entry_id, COUNT(*) AS c FROM attachments GROUP BY entry_id',
    );
    return <String, int>{
      for (final row in rows)
        row['entry_id']! as String: (row['c'] as int?) ?? 0,
    };
  }

  void deleteByEntry(String entryId) {
    _raw.execute('DELETE FROM attachments WHERE entry_id = ?', <Object?>[
      entryId,
    ]);
  }

  /// 库中仍被引用的全部附件哈希（GC 依据）。
  Set<String> referencedHashes() {
    final rows = _raw.select('SELECT DISTINCT sha256 FROM attachments');
    return rows.map((row) => row['sha256']! as String).toSet();
  }

  /// 未被任何条目引用的哈希（回收站条目仍算引用，避免恢复时丢失）。
  Set<String> orphanHashesFrom(Set<String> existingOnDisk) {
    final referenced = referencedHashes();
    return existingOnDisk.difference(referenced);
  }

  // ───────────────────── 附件字节（v2：存进数据库） ─────────────────────

  /// 写入/覆盖一份附件字节（同 sha 只存一份）。
  void putBlob(String sha256, Uint8List bytes) {
    _raw.execute(
      'INSERT INTO attachment_blobs (sha256, size, bytes) VALUES (?, ?, ?) '
      'ON CONFLICT(sha256) DO UPDATE SET size = excluded.size, bytes = excluded.bytes',
      <Object?>[sha256, bytes.length, bytes],
    );
  }

  /// 读回附件字节；库里没有返回 null。
  Uint8List? readBlob(String sha256) {
    final rows = _raw.select(
      'SELECT bytes FROM attachment_blobs WHERE sha256 = ?',
      <Object?>[sha256],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['bytes'];
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
  }

  bool hasBlob(String sha256) {
    final rows = _raw.select(
      'SELECT 1 FROM attachment_blobs WHERE sha256 = ? LIMIT 1',
      <Object?>[sha256],
    );
    return rows.isNotEmpty;
  }

  /// 附件索引里有、但库里还没有字节的哈希（老版本升级时用来回填）。
  Set<String> shasWithoutBlob() {
    final rows = _raw.select(
      'SELECT DISTINCT a.sha256 AS sha256 FROM attachments a '
      'LEFT JOIN attachment_blobs b ON b.sha256 = a.sha256 '
      'WHERE b.sha256 IS NULL',
    );
    return rows.map((row) => row['sha256']! as String).toSet();
  }

  /// 某份附件在索引里的扩展名（回填老文件时拼路径用）。
  String extensionOf(String sha256) {
    final rows = _raw.select(
      'SELECT filename FROM attachments WHERE sha256 = ? LIMIT 1',
      <Object?>[sha256],
    );
    if (rows.isEmpty) return '';
    return normalizeExtension(rows.first['filename']! as String);
  }

  /// 删掉没有任何索引引用的附件字节；返回删除条数。
  int deleteUnreferencedBlobs() {
    final before = blobCount();
    _raw.execute(
      'DELETE FROM attachment_blobs '
      'WHERE sha256 NOT IN (SELECT sha256 FROM attachments)',
    );
    return before - blobCount();
  }

  int blobCount() {
    final rows = _raw.select('SELECT COUNT(*) AS c FROM attachment_blobs');
    return (rows.first['c'] as int?) ?? 0;
  }
}
