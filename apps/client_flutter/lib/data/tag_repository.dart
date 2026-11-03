import 'package:sqlite3/sqlite3.dart';

import '../core/ids.dart';
import 'database.dart';

/// 标签仓储：标签只作为「条目的多对多标记」，正文里不写 `#tag`，
/// 导出时写进 front matter 的 `tags:`，导入时读回来。
class TagRepository {
  TagRepository(this._db);

  final AppDatabase _db;

  Database get _raw => _db.raw;

  /// 某篇日记的标签（按名字排序）。
  List<String> tagsOf(String entryId) {
    final rows = _raw.select(
      'SELECT t.name FROM entry_tags et JOIN tags t ON t.id = et.tag_id '
      'WHERE et.entry_id = ? ORDER BY t.name',
      <Object?>[entryId],
    );
    return rows
        .map((row) => row['name']! as String)
        .toList(growable: false);
  }

  /// 全库「条目 -> 标签」，列表页/检索一次取完，避免逐行查询。
  Map<String, List<String>> allTagsByEntry() {
    final rows = _raw.select(
      'SELECT et.entry_id AS entry_id, t.name AS name '
      'FROM entry_tags et JOIN tags t ON t.id = et.tag_id ORDER BY t.name',
    );
    final result = <String, List<String>>{};
    for (final row in rows) {
      result
          .putIfAbsent(row['entry_id']! as String, () => <String>[])
          .add(row['name']! as String);
    }
    return result;
  }

  /// 全库标签名（去重、排序；将来做标签云/自动补全用）。
  List<String> allNames() {
    final rows = _raw.select('SELECT name FROM tags ORDER BY name');
    return rows.map((row) => row['name']! as String).toList(growable: false);
  }

  /// 覆盖式设置某篇的标签：去空白、去重（忽略大小写）、顺带清掉没人用的标签。
  void setTags(String entryId, Iterable<String> names) {
    final cleaned = <String>[];
    final seen = <String>{};
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      if (!seen.add(name.toLowerCase())) continue;
      cleaned.add(name);
    }

    _raw.execute('BEGIN');
    try {
      _raw.execute('DELETE FROM entry_tags WHERE entry_id = ?', <Object?>[
        entryId,
      ]);
      for (final name in cleaned) {
        final existing = _raw.select(
          'SELECT id FROM tags WHERE name = ? COLLATE NOCASE',
          <Object?>[name],
        );
        final String tagId;
        if (existing.isEmpty) {
          tagId = newId();
          _raw.execute('INSERT INTO tags (id, name) VALUES (?, ?)', <Object?>[
            tagId,
            name,
          ]);
        } else {
          tagId = existing.first['id']! as String;
        }
        _raw.execute(
          'INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) VALUES (?, ?)',
          <Object?>[entryId, tagId],
        );
      }
      // 删掉已经没有任何日记使用的标签，避免越攒越多
      _raw.execute(
        'DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM entry_tags)',
      );
      _raw.execute('COMMIT');
    } catch (error) {
      _raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 导入合并用：把 [names] 追加到已有标签上（不覆盖已有标签）。
  void addTags(String entryId, Iterable<String> names) {
    final merged = <String>[...tagsOf(entryId), ...names];
    setTags(entryId, merged);
  }
}
