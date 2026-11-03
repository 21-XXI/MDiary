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
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:sqlite3/open.dart';

/// 拖拽导入：文件要落盘、写 attachments 表、并把引用插进正文（导出的 .md 才带附件）。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory tempDir;
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mdiary_drop_');
    db = AppDatabase.inMemory();
    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final store = AttachmentStore(Directory('${tempDir.path}/attachments'));
    state = AppState(
      db: db,
      entryRepo: entryRepo,
      attachmentRepo: attachmentRepo,
      metaRepo: MetaRepository(db),
      store: store,
      markdownIo: MarkdownIo(
        entries: entryRepo,
        attachments: attachmentRepo,
        store: store,
      ),
      dataRootPath: tempDir.path,
      filePicker: () async => null,
      directoryPicker: (title) async => null,
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('拖入文件：新建当天日记 + 落盘 + 引用写进正文', () async {
    final png = File('${tempDir.path}/dropped.png')
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5]);

    final added = await state.attachDroppedFiles(<String>[png.path]);

    expect(added, 1);
    expect(state.entryRepo.count(), 1);
    final entry = state.entries.single;
    expect(entry.bodyMd, contains('assets/'));
    expect(entry.bodyMd, contains('.png'));
    expect(
      entry.bodyMd,
      contains('dropped.png'),
      reason: '附件名要写进 .md 正文（纯文本里也能看出是什么）',
    );

    final attachments = state.attachmentRepo.listByEntry(entry.id);
    expect(attachments, hasLength(1));
    expect(attachments.single.filename, 'dropped.png');
    expect(
      state.store.pathFor(attachments.single.sha256, '.png'),
      isNotNull,
      reason: '附件要真的落盘',
    );
  }, skip: skip);

  test('连拖多个文件：都挂到同一篇，正文里各有一条引用', () async {
    final a = File('${tempDir.path}/a.txt')..writeAsStringSync('aaa');
    final b = File('${tempDir.path}/b.txt')..writeAsStringSync('bbb');

    final added = await state.attachDroppedFiles(<String>[a.path, b.path]);

    expect(added, 2);
    expect(state.entryRepo.count(), 1);
    final entry = state.entries.single;
    expect(entry.bodyMd.split('assets/').length - 1, 2);
    expect(state.attachmentRepo.countsByEntry()[entry.id], 2);
  }, skip: skip);

  test('已选中某篇时，拖入的附件挂到它上面', () async {
    final old = await state.selectDay(DateTime(2025, 5, 20));
    state.draftChanged(title: '旧日记', immediate: true);
    await state.flushNow();

    final file = File('${tempDir.path}/x.bin')..writeAsBytesSync(<int>[9, 9]);
    await state.attachDroppedFiles(<String>[file.path]);

    expect(state.selected!.id, old.id);
    expect(state.attachmentRepo.listByEntry(old.id), hasLength(1));
    expect(state.entryRepo.count(), 1);
  }, skip: skip);

  test('不存在的路径直接忽略', () async {
    final added = await state.attachDroppedFiles(<String>[
      '${tempDir.path}/nope.png',
    ]);
    expect(added, 0);
    expect(state.entryRepo.count(), 0);
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
