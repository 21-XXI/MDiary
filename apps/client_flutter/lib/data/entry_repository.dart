import 'package:sqlite3/sqlite3.dart';

import '../core/ids.dart';
import 'database.dart';
import 'models.dart';

/// 条目仓储：唯一写入路径（UI 不直接写 SQL）。
class EntryRepository {
  EntryRepository(this._db);

  final AppDatabase _db;

  Database get _raw => _db.raw;

  /// 列表查询。[deleted] 为 true 时查回收站。
  List<Entry> query({String keyword = '', bool deleted = false}) {
    final sql = StringBuffer('SELECT * FROM entries WHERE ');
    sql.write(deleted ? 'deleted_at IS NOT NULL' : 'deleted_at IS NULL');
    final params = <Object?>[];
    final kw = keyword.trim();
    if (kw.isNotEmpty) {
      final pattern = '%${_escapeLike(kw)}%';
      sql.write(" AND (title LIKE ? ESCAPE '\\' OR body_md LIKE ? ESCAPE '\\')");
      params
        ..add(pattern)
        ..add(pattern);
    }
    sql.write(deleted
        ? ' ORDER BY deleted_at DESC'
        : ' ORDER BY pinned DESC, entry_date DESC, updated_at DESC');
    final rows = _raw.select(sql.toString(), params);
    return rows.map((row) => Entry.fromMap(Map<String, Object?>.from(row))).toList();
  }

  Entry? findById(String id) {
    final rows = _raw.select('SELECT * FROM entries WHERE id = ?', <Object?>[id]);
    if (rows.isEmpty) return null;
    return Entry.fromMap(Map<String, Object?>.from(rows.first));
  }

  Entry create({
    required String deviceId,
    DateTime? date,
    String title = '',
    String body = '',
  }) {
    final now = DateTime.now();
    final base = date ?? now;
    final entry = Entry(
      id: newId(),
      title: title,
      bodyMd: body,
      entryDate: DateTime(base.year, base.month, base.day),
      createdAt: now,
      updatedAt: now,
      rev: 1,
      pinned: false,
      deviceId: deviceId,
    );
    _raw.execute(
      'INSERT INTO entries (id, title, body_md, entry_date, created_at, updated_at, rev, pinned, device_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        entry.id,
        entry.title,
        entry.bodyMd,
        entry.entryDate.millisecondsSinceEpoch,
        entry.createdAt.millisecondsSinceEpoch,
        entry.updatedAt.millisecondsSinceEpoch,
        entry.rev,
        0,
        entry.deviceId,
      ],
    );
    return entry;
  }

  /// 保存正文与标题；返回写入后的条目。
  Entry saveContent(String id, {String? title, String? body}) {
    final current = findById(id);
    if (current == null) {
      throw StateError('条目不存在: $id');
    }
    final nextTitle = title ?? current.title;
    final nextBody = body ?? current.bodyMd;
    if (nextTitle == current.title && nextBody == current.bodyMd) {
      return current;
    }
    final updatedAt = DateTime.now();
    _raw.execute(
      'UPDATE entries SET title = ?, body_md = ?, updated_at = ?, rev = rev + 1 WHERE id = ?',
      <Object?>[nextTitle, nextBody, updatedAt.millisecondsSinceEpoch, id],
    );
    return current.copyWith(
      title: nextTitle,
      bodyMd: nextBody,
      updatedAt: updatedAt,
      rev: current.rev + 1,
    );
  }

  void setPinned(String id, bool pinned) {
    _raw.execute(
      'UPDATE entries SET pinned = ?, updated_at = ? WHERE id = ?',
      <Object?>[pinned ? 1 : 0, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void softDelete(String id) {
    _raw.execute(
      'UPDATE entries SET deleted_at = ?, updated_at = ? WHERE id = ?',
      <Object?>[DateTime.now().millisecondsSinceEpoch, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void restore(String id) {
    _raw.execute('UPDATE entries SET deleted_at = NULL WHERE id = ?', <Object?>[id]);
  }

  /// 物理删除（回收站彻底删除时调用）。
  void purge(String id) {
    _raw.execute('DELETE FROM entries WHERE id = ?', <Object?>[id]);
  }

  /// 导入去重：同一天 + 完全相同的正文视为同一条。
  bool existsSameContent(String bodyMd, DateTime entryDate) {
    final day = DateTime(entryDate.year, entryDate.month, entryDate.day);
    final rows = _raw.select(
      'SELECT id FROM entries WHERE body_md = ? AND entry_date = ? LIMIT 1',
      <Object?>[bodyMd, day.millisecondsSinceEpoch],
    );
    return rows.isNotEmpty;
  }

  int count({bool deleted = false}) {
    final rows = _raw.select(
      deleted
          ? 'SELECT COUNT(*) AS c FROM entries WHERE deleted_at IS NOT NULL'
          : 'SELECT COUNT(*) AS c FROM entries WHERE deleted_at IS NULL',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  static String _escapeLike(String input) => input
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
