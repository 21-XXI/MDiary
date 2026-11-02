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

/// AppState 的保存状态机：成功清 pending、失败保留并可在下次 flush 重试。
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
    tempDir = Directory.systemTemp.createTempSync('mdiary_state_');
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

  test('保存成功后 pending 清空、状态为 saved', () async {
    await state.createEntry();
    state.draftChanged(title: '标题', body: '正文');
    expect(state.hasUnsavedChanges, isTrue);
    expect(state.status, SaveStatus.dirty);

    await state.flushNow();

    expect(state.status, SaveStatus.saved);
    expect(state.hasUnsavedChanges, isFalse);
    expect(state.entryRepo.query().single.title, '标题');
  }, skip: skip);

  test('写库失败时保留 pending，下次 flush 会重试而不是静默丢弃', () async {
    await state.createEntry();
    state.draftChanged(title: '会被保留', body: '正文');

    // 破坏数据库：让 saveContent 抛错
    db.raw.execute('DROP TABLE entries');
    await state.flushNow();

    expect(state.status, SaveStatus.error);
    expect(state.lastError, isNotNull);
    expect(
      state.hasUnsavedChanges,
      isTrue,
      reason: '失败必须保留待保存内容，否则一次写库失败就等于丢稿',
    );

    // 再次 flush 仍然尝试写（说明 pending 没有被清掉），依旧失败
    await state.flushNow();
    expect(state.status, SaveStatus.error);
    expect(state.hasUnsavedChanges, isTrue);
  }, skip: skip);

  test('Ctrl+S 路径（flushNow）在无 pending 时是空操作', () async {
    await state.createEntry();
    await state.flushNow();
    expect(state.hasUnsavedChanges, isFalse);

    await state.flushNow();
    expect(state.status, SaveStatus.saved);
  }, skip: skip);

  test('切换条目前会先落库，切回后内容仍在', () async {
    final first = await state.createEntry();
    state.draftChanged(title: '第一篇', body: '内容一');

    final second = await state.createEntry();
    // createEntry 内部会 flush 第一篇
    expect(state.entryRepo.findById(first.id)!.title, '第一篇');

    state.draftChanged(title: '第二篇', body: '内容二');
    await state.select(state.entryRepo.findById(first.id)!);
    expect(state.entryRepo.findById(second.id)!.title, '第二篇');
    expect(state.selected!.title, '第一篇');
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
