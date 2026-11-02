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
import 'package:sqlite3/open.dart';

/// 导入/导出的边界：目录外引用、子目录引用、缺失附件、BOM、无 front matter、
/// 中文文件名与大写扩展、同名导出冲突、重复导入。
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
    tempDir = Directory.systemTemp.createTempSync('mdiary_io_');
    db = AppDatabase.inMemory();
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    store = AttachmentStore(Directory('${tempDir.path}/archive'));
    io = MarkdownIo(entries: entries, attachments: attachments, store: store);
  });

  tearDown(() {
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<Directory> makeImportDir(String name) async {
    final dir = Directory('${tempDir.path}/$name');
    await dir.create(recursive: true);
    return dir;
  }

  test('目录外引用（../outside.png）不会被复制进附件库', () async {
    final outside = File('${tempDir.path}/outside.png')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final dir = await makeImportDir('import_a');
    File('${dir.path}/note.md').writeAsStringSync(
      '---\ntitle: 外链测试\ndate: 2026-11-02\n---\n\n![out](../outside.png)',
    );

    final result = await io.importDirectory(dir.path, deviceId: 'd');
    expect(result.imported, 1);
    expect(result.errors, isEmpty);

    // 没有附件入库，正文保留原样（不复制 => 不改写）
    final entry = entries.query().single;
    expect(attachments.listByEntry(entry.id), isEmpty);
    expect(entry.bodyMd, contains('../outside.png'));
    // 目录外文件未被读取（仍原样存在，且附件目录不存在）
    expect(outside.existsSync(), isTrue);
    expect(Directory('${tempDir.path}/archive').existsSync(), isFalse);
  }, skip: skip);

  test('目录内子目录引用被复制并改写为 assets/<hash>', () async {
    final dir = await makeImportDir('import_b');
    final assets = Directory('${dir.path}/images')..createSync();
    File('${assets.path}/pic.png').writeAsBytesSync(<int>[5, 6, 7]);
    File('${dir.path}/note.md')
        .writeAsStringSync('---\ntitle: 子目录\n---\n\n![pic](images/pic.png)');

    final result = await io.importDirectory(dir.path, deviceId: 'd');
    expect(result.imported, 1);

    final entry = entries.query().single;
    final list = attachments.listByEntry(entry.id);
    expect(list.length, 1, reason: '目录内图片应被复制进附件库');
    expect(entry.bodyMd, contains('assets/${list.single.sha256}.png'));
    expect(entry.bodyMd.contains('images/pic.png'), isFalse);
  }, skip: skip);

  test('引用不存在时导入仍成功，仅保留原链接', () async {
    final dir = await makeImportDir('import_c');
    File('${dir.path}/note.md')
        .writeAsStringSync('---\ntitle: 缺失图片\n---\n\n![x](images/missing.png)');

    final result = await io.importDirectory(dir.path, deviceId: 'd');
    expect(result.imported, 1);
    expect(result.errors, isEmpty);
    final entry = entries.query().single;
    expect(attachments.listByEntry(entry.id), isEmpty);
    expect(entry.bodyMd, contains('images/missing.png'));
  }, skip: skip);

  test('带 BOM 与 CRLF 的 md 正常导入', () async {
    final dir = await makeImportDir('import_d');
    final content = '\uFEFF---\r\ntitle: BOM 文件\r\n---\r\n\r\n正文内容\r\n';
    File('${dir.path}/bom.md').writeAsStringSync(content);

    final result = await io.importDirectory(dir.path, deviceId: 'd');
    expect(result.imported, 1);
    final entry = entries.query().single;
    expect(entry.title, 'BOM 文件');
    expect(entry.bodyMd.contains('\r'), isFalse);
    expect(entry.bodyMd, contains('正文内容'));
  }, skip: skip);

  test('没有 front matter 时用文件名作标题、文件修改时间作日期', () async {
    final dir = await makeImportDir('import_e');
    final file = File('${dir.path}/我的随笔.md')..writeAsStringSync('# 随手写\n正文');
    file.setLastModifiedSync(DateTime(2025, 6, 7, 8, 9));

    final result = await io.importDirectory(dir.path, deviceId: 'd');
    expect(result.imported, 1);
    final entry = entries.query().single;
    expect(entry.title, '我的随笔');
    expect(entry.entryDate, DateTime(2025, 6, 7));
  }, skip: skip);

  test('中文文件名与大写扩展名：扩展名归一化为小写', () async {
    final dir = await makeImportDir('import_f');
    File('${dir.path}/照片.PNG').writeAsBytesSync(<int>[9, 9, 9]);
    File('${dir.path}/note.md')
        .writeAsStringSync('---\ntitle: 中文附件\n---\n\n![图](照片.PNG)');

    final result = await io.importDirectory(dir.path, deviceId: 'd');
    expect(result.imported, 1);
    final entry = entries.query().single;
    final list = attachments.listByEntry(entry.id);
    expect(list.length, 1);
    expect(list.single.filename, '照片.PNG');
    expect(entry.bodyMd, contains('.png'), reason: '引用应使用归一化后的扩展名');
    expect(store.pathFor(list.single.sha256, '.png'), isNotNull);
  }, skip: skip);

  test('同日期同标题导出不覆盖，第二条自动加序号', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 2),
      title: '同名',
      body: 'A',
    );
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 2),
      title: '同名',
      body: 'B',
    );

    final outDir = Directory('${tempDir.path}/out')..createSync();
    final result = await io.exportAll(outDir.path);
    expect(result.files.length, 2);
    final names = result.files
        .map((f) => File(f).uri.pathSegments.last)
        .toList();
    expect(names.where((n) => n == '2026-11-02-同名.md').length, 1);
    expect(names.any((n) => n.contains('(2)')), isTrue);
  }, skip: skip);

  test('同一目录重复导入：全部按重复跳过', () async {
    final dir = await makeImportDir('import_g');
    File('${dir.path}/a.md')
        .writeAsStringSync('---\ntitle: A\ndate: 2026-01-01\n---\n\n内容 A');

    final first = await io.importDirectory(dir.path, deviceId: 'd');
    expect(first.imported, 1);

    final second = await io.importDirectory(dir.path, deviceId: 'd');
    expect(second.imported, 0);
    expect(second.skipped, 1);
    expect(entries.count(), 1);
  }, skip: skip);

  test('导入目录不存在时返回错误而不是抛异常', () async {
    final result = await io.importDirectory(
      '${tempDir.path}/not_exists',
      deviceId: 'd',
    );
    expect(result.imported, 0);
    expect(result.errors, isNotEmpty);
  }, skip: skip);

  test('单篇导出后再导入，正文与标题一致（无附件）', () async {
    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 3, 4),
      title: '往返',
      body: '# 标题\n\n正文段落。',
    );
    final outDir = Directory('${tempDir.path}/one')..createSync();
    await io.exportEntry(entries.findById(entry.id)!, outDir.path);

    final result = await io.importDirectory(outDir.path, deviceId: 'd2');
    // 同库内已存在相同内容，导入会跳过
    expect(result.skipped, 1);

    final db2 = AppDatabase.inMemory();
    final entries2 = EntryRepository(db2);
    final io2 = MarkdownIo(
      entries: entries2,
      attachments: AttachmentRepository(db2),
      store: AttachmentStore(Directory('${tempDir.path}/archive2')),
    );
    final fresh = await io2.importDirectory(outDir.path, deviceId: 'd3');
    expect(fresh.imported, 1);
    final restored = entries2.query().single;
    expect(restored.title, '往返');
    expect(restored.bodyMd, contains('正文段落。'));
    db2.dispose();
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
