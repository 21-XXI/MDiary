@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_document.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:sqlite3/open.dart';

/// 数据层集成测试：真实 SQLite + 真实附件目录 + 真实导入导出。
/// 需要 sqlite3.dll（发布产物里自带），找不到时整组跳过。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }

  late Directory tempDir;
  late AppDatabase db;
  late EntryRepository entries;
  late AttachmentRepository attachments;
  late MetaRepository meta;
  late AttachmentStore store;
  late MarkdownIo io;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mdiary_test_');
    db = AppDatabase.inMemory();
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    meta = MetaRepository(db);
    store = AttachmentStore(Directory('${tempDir.path}/attachments'));
    io = MarkdownIo(entries: entries, attachments: attachments, store: store);
  });

  tearDown(() {
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('数据库与迁移', () {
    test('初始化后 user_version = 2 且表齐全', () {
      final version = db.raw
          .select('PRAGMA user_version')
          .first['user_version'];
      expect(version, 2);
      final tables = db.raw
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'])
          .toSet();
      expect(
        tables,
        containsAll(<String>[
          'entries',
          'attachments',
          'tags',
          'entry_tags',
          'app_meta',
        ]),
      );
    });

    test('meta 键值可读写', () {
      meta.set('device_id', 'abc');
      expect(meta.get('device_id'), 'abc');
      meta.set('device_id', 'xyz');
      expect(meta.get('device_id'), 'xyz');
      expect(meta.getInt('missing'), isNull);
    });
  }, skip: dll == null ? '未找到 sqlite3.dll（先执行 flutter build windows）' : false);

  group('条目 CRUD 与搜索', () {
    test('创建、保存、按关键字搜索', () {
      final entry = entries.create(
        deviceId: 'dev',
        date: DateTime(2026, 11, 2),
        title: '杭州三日',
        body: '西湖下雨',
      );
      expect(entries.count(), 1);

      final saved = entries.saveContent(entry.id, body: '西湖下雨，龙井村喝茶');
      expect(saved.rev, 2);
      expect(entries.findById(entry.id)!.bodyMd.contains('龙井村'), isTrue);

      expect(entries.query(keyword: '龙井').length, 1);
      expect(entries.query(keyword: '不存在').length, 0);
      expect(entries.query(keyword: '杭州').length, 1);
    });

    test('LIKE 通配符被转义，不会误命中', () {
      entries.create(deviceId: 'dev', title: '100% 完成', body: 'a_b');
      entries.create(deviceId: 'dev', title: '其它', body: 'normal');
      expect(entries.query(keyword: '%').length, 1);
      expect(entries.query(keyword: '_').length, 1);
    });

    test('置顶优先、软删除进回收站、恢复与彻底删除', () {
      final a = entries.create(
        deviceId: 'dev',
        title: 'A',
        date: DateTime(2026, 11, 1),
      );
      final b = entries.create(
        deviceId: 'dev',
        title: 'B',
        date: DateTime(2026, 11, 2),
      );
      entries.setPinned(a.id, true);
      expect(entries.query().first.id, a.id);

      entries.softDelete(a.id);
      expect(entries.query().first.id, b.id);
      expect(entries.count(deleted: true), 1);

      entries.restore(a.id);
      expect(entries.count(deleted: true), 0);

      entries.purge(b.id);
      expect(entries.count(), 1);
    });

    test('同正文 + 同日期的重复导入判定', () {
      final date = DateTime(2026, 11, 2);
      entries.create(deviceId: 'dev', date: date, body: '正文');
      expect(entries.existsSameContent('正文', date), isTrue);
      expect(entries.existsSameContent('正文', DateTime(2026, 11, 3)), isFalse);
    });
  }, skip: dll == null ? '未找到 sqlite3.dll（先执行 flutter build windows）' : false);

  group('附件库', () {
    test('内容寻址写入、同内容去重', () async {
      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 256),
      );
      final first = await store.storeBytes(bytes, 'pic.png');
      final second = await store.storeBytes(bytes, 'copy.png');
      expect(first.sha256, second.sha256);
      expect(File(first.path).existsSync(), isTrue);
      expect(store.pathFor(first.sha256, '.png'), first.path);
      final files = Directory('${tempDir.path}/attachments')
          .listSync(recursive: true)
          .whereType<File>();
      expect(files.length, 1, reason: '同内容只应存一份');
    });

    test('超过单文件上限拒绝（默认 100 MB，这里用 1 KB 的 store 验证）', () async {
      final limited = AttachmentStore(
        Directory('${tempDir.path}/limited'),
        maxFileBytes: 1024,
      );
      final big = Uint8List(2048);
      expect(
        () => limited.storeBytes(big, 'big.bin'),
        throwsA(isA<AttachmentTooLargeException>()),
      );
    });

    test('GC 删除无引用附件，保留有引用附件', () async {
      final keep = await store.storeBytes(
        Uint8List.fromList(<int>[1, 2, 3]),
        'keep.txt',
      );
      final drop = await store.storeBytes(
        Uint8List.fromList(<int>[4, 5, 6]),
        'drop.txt',
      );
      final entry = entries.create(deviceId: 'dev', title: 't');
      attachments.insert(
        entryId: entry.id,
        sha256: keep.sha256,
        filename: 'keep.txt',
        mime: 'text/plain',
        sizeBytes: keep.sizeBytes,
      );
      final removed = await store.collectGarbage(
        attachments.referencedHashes(),
      );
      expect(removed, 1);
      expect(store.pathFor(keep.sha256, '.txt'), isNotNull);
      expect(store.pathFor(drop.sha256, '.txt'), isNull);
    });

    test('附件相对引用格式', () async {
      final blob = await store.storeBytes(
        Uint8List.fromList(<int>[9, 9, 9]),
        'a.JPG',
      );
      expect(blob.relativeRef, 'assets/${blob.sha256}.jpg');
    });
  }, skip: dll == null ? '未找到 sqlite3.dll（先执行 flutter build windows）' : false);

  group('导入导出', () {
    test('单篇导出带 front matter 与 assets/ 附件', () async {
      final entry = entries.create(
        deviceId: 'dev',
        date: DateTime(2026, 11, 2),
        title: '雨天/测试',
        body: '正文',
      );
      final blob = await store.storeBytes(
        Uint8List.fromList(<int>[7, 7, 7]),
        'x.png',
      );
      attachments.insert(
        entryId: entry.id,
        sha256: blob.sha256,
        filename: 'x.png',
        mime: 'image/png',
        sizeBytes: blob.sizeBytes,
      );
      entries.saveContent(entry.id, body: '图为 ![](assets/${blob.sha256}.png)');

      final outDir = Directory('${tempDir.path}/out')..createSync();
      final path = await io.exportEntry(
        entries.findById(entry.id)!,
        outDir.path,
      );
      final file = File(path);
      expect(file.existsSync(), isTrue);
      expect(
        path.split(Platform.pathSeparator).last,
        startsWith('2026-11-02-'),
      );

      final content = file.readAsStringSync();
      final doc = parseMarkdownDocument(content);
      expect(doc.title, '雨天/测试');
      expect(doc.date, DateTime(2026, 11, 2));
      expect(
        File('${outDir.path}/assets/${blob.sha256}.png').existsSync(),
        isTrue,
      );
    });

    test('整库导出 + 导入还原（含重复跳过）', () async {
      final a = entries.create(
        deviceId: 'dev',
        date: DateTime(2026, 10, 1),
        title: '第一篇',
        body: '# 第一篇\n内容一',
      );
      entries.create(
        deviceId: 'dev',
        date: DateTime(2026, 10, 2),
        title: '第二篇',
        body: '内容二',
      );
      entries.saveContent(a.id, body: '# 第一篇\n内容一');
      final outDir = Directory('${tempDir.path}/lib_out')..createSync();
      final result = await io.exportAll(outDir.path);
      expect(result.entries, 2);
      expect(result.files.length, 2);

      // 导入到一个全新的库
      final db2 = AppDatabase.inMemory();
      final entries2 = EntryRepository(db2);
      final attachments2 = AttachmentRepository(db2);
      final store2 = AttachmentStore(Directory('${tempDir.path}/attachments2'));
      final io2 = MarkdownIo(
        entries: entries2,
        attachments: attachments2,
        store: store2,
      );

      final imported = await io2.importDirectory(outDir.path, deviceId: 'dev2');
      expect(imported.imported, 2);
      expect(imported.errors, isEmpty);
      expect(entries2.count(), 2);
      expect(entries2.query(keyword: '内容二').length, 1);

      // 再导入一次：全部按重复跳过
      final again = await io2.importDirectory(outDir.path, deviceId: 'dev2');
      expect(again.imported, 0);
      expect(again.skipped, 2);
      expect(entries2.count(), 2);
      db2.dispose();
    });
  }, skip: dll == null ? '未找到 sqlite3.dll（先执行 flutter build windows）' : false);
}

String? _locateSqlite3() {
  final fromEnv = Platform.environment['MDIARY_SQLITE_DLL'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  final candidates = <String>[
    'build/windows/x64/runner/Release/sqlite3.dll',
    'build/windows/x64/runner/Debug/sqlite3.dll',
    '../build/windows/x64/runner/Release/sqlite3.dll',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}
