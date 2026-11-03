@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 标签：多对多存取、参与搜索、导出写 front matter、导入读回来。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late AppDatabase db;
  late EntryRepository entries;
  late TagRepository tags;

  setUp(() {
    db = AppDatabase.inMemory();
    entries = EntryRepository(db);
    tags = TagRepository(db);
  });
  tearDown(() => db.dispose());

  test('设置标签：去空白、去重（忽略大小写）、按名字取回', () {
    final entry = entries.create(deviceId: 'd', title: '杭州');
    tags.setTags(entry.id, <String>[' 旅行 ', '旅行', 'Travel', 'travel', '']);

    expect(tags.tagsOf(entry.id), <String>['Travel', '旅行']);
  }, skip: skip);

  test('一个标签可以挂在多篇日记上；没人用的标签会被清掉', () {
    final a = entries.create(deviceId: 'd', title: 'A');
    final b = entries.create(deviceId: 'd', title: 'B');
    tags.setTags(a.id, <String>['旅行']);
    tags.setTags(b.id, <String>['旅行', '工作']);

    expect(tags.allNames(), <String>['工作', '旅行']);
    expect(tags.allTagsByEntry()[a.id], <String>['旅行']);
    expect(tags.allTagsByEntry()[b.id], <String>['工作', '旅行']);

    tags.setTags(b.id, <String>['旅行']);
    expect(tags.allNames(), <String>['旅行'], reason: '「工作」已经没人用了');
  }, skip: skip);

  test('搜索能命中标签名', () {
    final a = entries.create(deviceId: 'd', title: '无标题', body: '正文');
    final b = entries.create(deviceId: 'd', title: '另一篇', body: '别的正文');
    tags.setTags(a.id, <String>['旅行', '杭州']);

    final hit = entries.query(keyword: '杭州');
    expect(hit.map((e) => e.id), <String>[a.id]);
    expect(entries.query(keyword: '旅行').map((e) => e.id), <String>[a.id]);
    expect(entries.query(keyword: '另一篇').map((e) => e.id), <String>[b.id]);
    expect(entries.query(keyword: '不存在'), isEmpty);
  }, skip: skip);

  test('导出写 tags 到 front matter，再导入能读回标签', () async {
    final temp = Directory.systemTemp.createTempSync('mdiary_tags_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final store = AttachmentStore(Directory(p.join(temp.path, 'attachments')));
    final io = MarkdownIo(
      entries: entries,
      attachments: AttachmentRepository(db),
      store: store,
      tags: tags,
    );

    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 3),
      title: '杭州三日',
      body: '西湖下雨。',
    );
    tags.setTags(entry.id, <String>['旅行', '杭州']);

    final out = Directory(p.join(temp.path, 'out'))..createSync();
    final file = File(await io.exportEntry(entry, out.path));
    final content = file.readAsStringSync();
    expect(content, contains('tags: ['));
    expect(content, contains('旅行'));
    expect(content, contains('杭州'));

    // 导入回一个空库
    final other = AppDatabase.inMemory();
    addTearDown(other.dispose);
    final otherEntries = EntryRepository(other);
    final otherTags = TagRepository(other);
    final importer = MarkdownIo(
      entries: otherEntries,
      attachments: AttachmentRepository(other),
      store: AttachmentStore(Directory(p.join(temp.path, 'attachments2'))),
      tags: otherTags,
    );
    final result = await importer.importDirectory(
      out.path,
      deviceId: 'd2',
    );
    expect(result.imported, 1);
    final imported = otherEntries.query().single;
    expect(imported.title, '杭州三日');
    expect(otherTags.tagsOf(imported.id).toSet(), <String>{'旅行', '杭州'});
  }, skip: skip);

  test('addTags 合并不覆盖已有标签', () {
    final entry = entries.create(deviceId: 'd', title: '合并');
    tags.setTags(entry.id, <String>['旧标签']);
    tags.addTags(entry.id, <String>['新标签', '旧标签']);
    expect(tags.tagsOf(entry.id).toSet(), <String>{'旧标签', '新标签'});
  }, skip: skip);
}

String? _locateSqlite3() {
  final fromEnv = Platform.environment['MDIARY_SQLITE_DLL'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  for (final candidate in <String>[
    'build/windows/x64/runner/Release/sqlite3.dll',
    'build/windows/x64/runner/Debug/sqlite3.dll',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}
