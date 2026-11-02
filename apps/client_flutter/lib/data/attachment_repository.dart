import 'package:sqlite3/sqlite3.dart';

import '../core/ids.dart';
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

  /// 每个条目的附件数（列表页角标一次查完，避免按行 N 次查询）。
  Map<String, int> countsByEntry() {
    final rows = _raw.select('SELECT entry_id, COUNT(*) AS c FROM attachments GROUP BY entry_id');
    return <String, int>{
      for (final row in rows) row['entry_id']! as String: (row['c'] as int?) ?? 0,
    };
  }

  void deleteByEntry(String entryId) {
    _raw.execute('DELETE FROM attachments WHERE entry_id = ?', <Object?>[entryId]);
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
}
