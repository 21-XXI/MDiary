@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:sqlite3/open.dart';

/// 交叉状态：搜索 × 回收站 × 置顶 × 附件计数，验证「一个操作不会让另一个视图变脏」。
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
    tempDir = Directory.systemTemp.createTempSync('mdiary_mix_');
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

  Future<String> seed(String title, String body, {DateTime? date}) async {
    final entry = await state.createEntry(date: date);
    state.draftChanged(title: title, body: body);
    await state.flushNow();
    await state.refresh();
    return entry.id;
  }

  test('搜索态下删除条目：列表、回收站计数、选中态同步', () async {
    await seed('杭州游记', '西湖下雨');
    await seed('北京出差', '开会');

    state.setQuery('杭州');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(state.entries.length, 1, reason: '搜索应只命中一篇');

    // 先选中被搜到的那篇，再删除：验证「删除当前条目后选中态被清空」
    final target = state.entries.single;
    await state.select(target);
    await state.deleteEntry(target);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(state.entries, isEmpty, reason: '删除后搜索结果应为空');
    expect(state.trashCount, 1, reason: '回收站计数应同步 +1');
    expect(state.selected, isNull, reason: '删除当前条目后不应仍选中它');

    state.setQuery('');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(state.entries.length, 1, reason: '清空搜索后应只剩未删除的那篇');
  }, skip: skip);

  test('回收站恢复后重新出现在列表，且不污染搜索结果', () async {
    final id = await seed('待恢复', '内容');
    await state.deleteEntry(state.entryRepo.findById(id)!);
    expect(state.entries, isEmpty);
    expect(state.trashCount, 1);

    state.setQuery('待恢复');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(state.entries, isEmpty, reason: '回收站里的条目不应出现在搜索结果');

    await state.restoreEntry(state.entryRepo.query(deleted: true).single);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(state.trashCount, 0);
    expect(state.entries.length, 1, reason: '恢复后应重新命中搜索');
    expect(state.entries.single.title, '待恢复');
  }, skip: skip);

  test('彻底删除后：附件文件被回收、附件计数归零、条目消失', () async {
    final id = await seed('带附件', '正文');
    final entry = state.entryRepo.findById(id)!;
    final blob = await state.store.storeBytes(
      Uint8List.fromList(<int>[1, 2, 3, 4]),
      'a.png',
    );
    state.attachmentRepo.insert(
      entryId: id,
      sha256: blob.sha256,
      filename: 'a.png',
      mime: 'image/png',
      sizeBytes: blob.sizeBytes,
    );
    await state.refresh();
    expect(state.attachmentCountOf(id), 1);

    await state.deleteEntry(entry);
    // 回收站期间附件仍保留（可恢复）
    expect(state.attachmentCountOf(id), 1);
    expect(state.store.pathFor(blob.sha256, '.png'), isNotNull);

    await state.purgeEntry(state.entryRepo.query(deleted: true).single);

    expect(state.attachmentCountOf(id), 0);
    expect(state.entries, isEmpty);
    expect(state.trashCount, 0);
    expect(
      state.store.pathFor(blob.sha256, '.png'),
      isNull,
      reason: '彻底删除后附件文件应被 GC',
    );
  }, skip: skip);

  test('置顶与搜索组合：结果内仍按置顶优先', () async {
    final a = await seed('普通 A', '内容 A');
    final b = await seed('普通 B', '内容 B');
    await state.togglePin(state.entryRepo.findById(b)!);

    state.setQuery('普通');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(state.entries.length, 2);
    expect(state.entries.first.id, b, reason: '置顶条目应排在最前');

    state.setQuery('内容 A');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(state.entries.single.id, a);
  }, skip: skip);

  test('连续两次新建会清掉前一个空草稿，不产生垃圾条目', () async {
    await state.createEntry();
    await state.createEntry();
    expect(state.entries.length, 1, reason: '空草稿应被清理');
    expect(state.entryRepo.count(), 1);
  }, skip: skip);

  test('编辑中途切换条目：两篇内容都正确落库', () async {
    final a = await state.createEntry();
    state.draftChanged(title: 'A 篇', body: 'A 内容');

    final b = await state.createEntry();
    state.draftChanged(title: 'B 篇', body: 'B 内容');

    await state.select(state.entryRepo.findById(a.id));
    expect(state.entryRepo.findById(a.id)!.bodyMd, 'A 内容');
    expect(state.entryRepo.findById(b.id)!.bodyMd, 'B 内容');
    expect(state.selected!.id, a.id);
    expect(state.hasUnsavedChanges, isFalse);
  }, skip: skip);

  test('删除到回收站再恢复，置顶状态保留', () async {
    final id = await seed('置顶的日记', '内容');
    await state.togglePin(state.entryRepo.findById(id)!);
    expect(state.entryRepo.findById(id)!.pinned, isTrue);

    await state.deleteEntry(state.entryRepo.findById(id)!);
    await state.restoreEntry(state.entryRepo.query(deleted: true).single);

    expect(state.entryRepo.findById(id)!.pinned, isTrue);
    expect(state.entries.single.pinned, isTrue);
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
