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
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 导入格式：`父文件夹/日期/当期.md` + 同目录附件。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory sandbox;
  late AppDatabase db;
  late EntryRepository entries;
  late AttachmentRepository attachments;
  late AttachmentStore store;
  late MarkdownIo io;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_import_folder_');
    db = AppDatabase.inMemory();
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    store = AttachmentStore(
      Directory(p.join(sandbox.path, 'attachments')),
      blobs: attachments,
    );
    io = MarkdownIo(entries: entries, attachments: attachments, store: store);
  });

  tearDown(() {
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  Directory dateFolder(String parent, String date) => Directory(
    p.join(sandbox.path, parent, date),
  )..createSync(recursive: true);

  test('日期文件夹决定日期，同目录附件自动导入', () async {
    final folder = dateFolder('我的日记', '2026-11-06');
    File(p.join(folder.path, '当期.md')).writeAsStringSync('今天去了西湖，风很大。');
    File(p.join(folder.path, '西湖.png')).writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(folder.path, '发票.txt')).writeAsStringSync('住宿费 380 元');

    final result = await io.importDirectory(
      p.join(sandbox.path, '我的日记'),
      deviceId: 'd',
    );

    expect(result.imported, 1);
    final entry = entries.query().single;
    expect(entry.entryDate, DateTime(2026, 11, 6));
    expect(entry.bodyMd, contains('## 附件'));
    expect(entry.bodyMd, contains('西湖.png'));
    expect(entry.bodyMd, contains('发票.txt'));
    expect(attachments.listByEntry(entry.id), hasLength(2));
  }, skip: skip);

  test('正文已引用的图片不会重复导入', () async {
    final folder = dateFolder('日记', '2026年11月7日');
    File(
      p.join(folder.path, '当期.md'),
    ).writeAsStringSync('看图：![](西湖.png)');
    File(p.join(folder.path, '西湖.png')).writeAsBytesSync(<int>[9, 9]);

    final result = await io.importDirectory(
      p.join(sandbox.path, '日记'),
      deviceId: 'd',
    );

    expect(result.imported, 1);
    final entry = entries.query().single;
    expect(entry.entryDate, DateTime(2026, 11, 7));
    expect(attachments.listByEntry(entry.id), hasLength(1));
    expect(entry.bodyMd, isNot(contains('## 附件')));
  }, skip: skip);

  test('没有日期文件夹时保持旧行为（不自动收集附件）', () async {
    final folder = Directory(p.join(sandbox.path, '随手记'))
      ..createSync(recursive: true);
    File(p.join(folder.path, '无日期.md')).writeAsStringSync('普通导入。');
    File(p.join(folder.path, '无关.png')).writeAsBytesSync(<int>[1]);

    final result = await io.importDirectory(
      p.join(sandbox.path, '随手记'),
      deviceId: 'd',
    );

    expect(result.imported, 1);
    final entry = entries.query().single;
    expect(attachments.listByEntry(entry.id), isEmpty);
    expect(entry.bodyMd, isNot(contains('## 附件')));
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
