@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_document.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:sqlite3/open.dart';

/// 搜索与文本边界：注入串、转义符、emoji、超长关键词、特殊标题往返。
/// 这些都是用户随手输入就能触发、但常规用例容易漏掉的路径。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory tempDir;
  late AppDatabase db;
  late EntryRepository entries;
  late AttachmentRepository attachments;
  late AttachmentStore store;
  late MarkdownIo io;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mdiary_edge_');
    db = AppDatabase.inMemory();
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    store = AttachmentStore(Directory('${tempDir.path}/attachments'));
    io = MarkdownIo(entries: entries, attachments: attachments, store: store);
  });

  tearDown(() {
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('搜索健壮性', () {
    test('SQL 注入串只当普通关键词，不破坏表结构', () {
      entries.create(deviceId: 'd', title: '正常日记', body: '内容');
      final evil = "'; DROP TABLE entries; --";
      final hits = entries.query(keyword: evil);

      expect(hits, isEmpty);
      // 表还在，数据还在
      expect(entries.count(), 1);
      expect(entries.query().single.title, '正常日记');
    });

    test('关键词里的 % 与 _ 被转义，不会变成通配符', () {
      entries.create(deviceId: 'd', title: '100% 完成', body: 'a_b');
      entries.create(deviceId: 'd', title: '其它', body: 'plain');

      expect(entries.query(keyword: '100%').length, 1);
      expect(entries.query(keyword: '%').length, 1, reason: '只应命中含字面 % 的那篇');
      expect(entries.query(keyword: '_').length, 1, reason: '只应命中含字面 _ 的那篇');
    });

    test('反斜杠关键词不触发转义错误', () {
      entries.create(deviceId: 'd', title: r'路径 C:\Users\me', body: '转义');
      expect(entries.query(keyword: r'C:\Users').length, 1);
      expect(entries.query(keyword: r'\').length, 1);
    });

    test('emoji 与中英混排可被检索', () {
      entries.create(deviceId: 'd', title: '今天很开心 😀', body: 'mixed 内容 with English');
      expect(entries.query(keyword: '😀').length, 1);
      expect(entries.query(keyword: 'English').length, 1);
      expect(entries.query(keyword: '常开').length, 0);
    });

    test('空白关键词按“无过滤”处理，超长关键词不报错', () {
      entries.create(deviceId: 'd', title: 'A');
      entries.create(deviceId: 'd', title: 'B');

      expect(entries.query(keyword: '   ').length, 2);
      expect(entries.query(keyword: 'x' * 10000), isEmpty);
      expect(entries.count(), 2);
    });

    test('大小写不敏感（英文）', () {
      entries.create(deviceId: 'd', title: 'Hello World', body: 'Dart And Flutter');
      expect(entries.query(keyword: 'hello').length, 1);
      expect(entries.query(keyword: 'FLUTTER').length, 1);
    });
  }, skip: skip);

  group('特殊文本往返', () {
    final titles = <String>[
      '含冒号: 的标题',
      '含井号 # 与引号 " 的标题',
      '含单引号 \' 的标题',
      'emoji 😀🧪 标题',
      '很长的标题 ${'长' * 120}',
      '    前后有空格    ',
    ];

    for (final title in titles) {
      test('导出再导入后标题保留：${title.length > 20 ? '${title.substring(0, 20)}…' : title}', () async {
        final entry = entries.create(deviceId: 'd', date: DateTime(2026, 11, 2), title: title, body: '正文');
        final outDir = Directory('${tempDir.path}/out_${title.hashCode}')..createSync();
        final path = await io.exportEntry(entries.findById(entry.id)!, outDir.path);

        // 直接解析导出文件
        final doc = parseMarkdownDocument(File(path).readAsStringSync());
        expect(doc.title, title.trim().isEmpty ? '无标题' : title.trim());
        expect(doc.date, DateTime(2026, 11, 2));

        // 导入到新库
        final db2 = AppDatabase.inMemory();
        final entries2 = EntryRepository(db2);
        final io2 = MarkdownIo(
          entries: entries2,
          attachments: AttachmentRepository(db2),
          store: AttachmentStore(Directory('${tempDir.path}/att2_${title.hashCode}')),
        );
        final result = await io2.importDirectory(outDir.path, deviceId: 'd2');
        expect(result.imported, 1);
        expect(result.errors, isEmpty);
        expect(entries2.query().single.title.trim(), doc.title);
        db2.dispose();
      }, skip: skip);
    }
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
