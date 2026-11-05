@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/app_paths.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// v1.1.1 打磨项：备份/压缩/缓存、回收站全部恢复、标签筛选与管理、搜索历史、
/// 导出可读附件名、失效库记录过滤。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory sandbox;
  late Directory root;
  late AppState state;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('mdiary_polish_');
    root = Directory(p.join(sandbox.path, 'data'))..createSync();
    Directory(p.join(root.path, 'db')).createSync(recursive: true);
    AppPaths.adopt(
      DataRoot(path: root.path, source: DataRootSource.userChosen),
    );
    await AppPaths.adoptLibrary(p.join(root.path, 'db'));

    final db = AppDatabase.open(AppPaths.databaseFile);
    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final store = AttachmentStore(
      Directory(p.join(root.path, 'attachments')),
      blobs: attachmentRepo,
    );
    state = AppState(
      db: db,
      entryRepo: entryRepo,
      attachmentRepo: attachmentRepo,
      metaRepo: MetaRepository(db),
      tagRepository: TagRepository(db),
      store: store,
      markdownIo: MarkdownIo(
        entries: entryRepo,
        attachments: attachmentRepo,
        store: store,
        tags: TagRepository(db),
      ),
      filePicker: () async => null,
      directoryPicker: (title) async => p.join(sandbox.path, 'export'),
      dataRootPath: root.path,
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  Future<void> writeEntry(
    DateTime day,
    String title, {
    String body = '',
    List<String> tags = const <String>[],
  }) async {
    await state.selectDay(day);
    state.draftChanged(title: title, body: body, immediate: true);
    await state.flushNow();
    if (tags.isNotEmpty) {
      await state.setTags(state.selected!, tags);
    }
  }

  test('备份数据库：生成快照并只保留最近 7 份', () async {
    await writeEntry(DateTime(2026, 11, 1), '备份测试');

    final first = await state.backupDatabase();
    expect(File(first).existsSync(), isTrue);
    expect(p.dirname(first), state.backupDirectory);

    // 连续备份 9 次，只留 7 份
    for (var i = 0; i < 8; i++) {
      await state.backupDatabase();
    }
    expect(state.listBackups().length, lessThanOrEqualTo(7));

    // 快照能独立打开并读到内容
    final latest = state.listBackups().first;
    final db = AppDatabase.open(latest.path);
    expect(EntryRepository(db).count(), 1);
    db.dispose();
  }, skip: skip);

  test('自动备份：24 小时内只备份一次', () async {
    await writeEntry(DateTime(2026, 11, 1), '自动备份');
    expect(await state.autoBackupIfDue(), isNotNull);
    expect(await state.autoBackupIfDue(), isNull, reason: '刚备份过不再重复');
  }, skip: skip);

  test('压缩数据库：数据不丢，大小不增大', () async {
    for (var i = 0; i < 5; i++) {
      await writeEntry(DateTime(2026, 11, 1 + i), '第 $i 篇', body: 'x' * 5000);
    }
    final before = state.entryRepo.count();
    final (sizeBefore, sizeAfter) = await state.compactDatabase();
    expect(state.entryRepo.count(), before);
    expect(sizeAfter, lessThanOrEqualTo(sizeBefore));
  }, skip: skip);

  test('附件缓存：能统计占用并一键清空，之后仍能从库里重建', () async {
    await writeEntry(DateTime(2026, 11, 2), '缓存测试');
    final blob = await state.store.storeBytes(
      Uint8List.fromList(<int>[9, 9, 9]),
      'shot.png',
    );
    expect(await state.attachmentCacheBytes(), greaterThan(0));

    final freed = await state.clearAttachmentCache();
    expect(freed, greaterThan(0));
    expect(await state.attachmentCacheBytes(), 0);

    final rebuilt = state.store.pathFor(blob.sha256, '.png');
    expect(rebuilt, isNotNull);
    expect(File(rebuilt!).readAsBytesSync(), <int>[9, 9, 9]);
  }, skip: skip);

  test('回收站：全部恢复', () async {
    await writeEntry(DateTime(2026, 11, 1), '甲');
    await writeEntry(DateTime(2026, 11, 2), '乙');
    for (final entry in state.entries) {
      state.entryRepo.softDelete(entry.id);
    }
    await state.refresh();
    expect(state.trashCount, 2);

    final restored = await state.restoreAllDeleted();
    expect(restored, 2);
    expect(state.trashCount, 0);
    expect(state.entryRepo.count(), 2);
  }, skip: skip);

  test('标签：筛选、重命名（合并）与删除', () async {
    await writeEntry(DateTime(2026, 11, 1), '甲', tags: <String>['旅行']);
    await writeEntry(DateTime(2026, 11, 2), '乙', tags: <String>['工作']);

    state.setTagFilter('旅行');
    await state.refresh();
    expect(state.entries.single.title, '甲');
    state.setTagFilter(null);
    await state.refresh();
    expect(state.entries.length, 2);

    // 重命名 工作 -> 旅行：两篇都落到同一个标签
    await state.renameTag('工作', '旅行');
    expect(state.tagCounts.keys, <String>['旅行']);
    expect(state.tagCounts['旅行'], 2);

    await state.removeTag('旅行');
    expect(state.tagCounts, isEmpty);
    expect(state.entryRepo.count(), 2, reason: '删标签不删日记');
  }, skip: skip);

  test('搜索历史：记住、去重、可清空', () async {
    state.rememberQuery('杭州');
    state.rememberQuery('西湖');
    state.rememberQuery('杭州');
    expect(state.recentQueries, <String>['杭州', '西湖']);

    // 重启后仍然在（存在 app_meta）
    await state.refresh();
    expect(state.recentQueries.length, 2);

    state.clearQueryHistory();
    expect(state.recentQueries, isEmpty);
  }, skip: skip);

  test('导出附件名可读：`原名-sha8.ext`，正文引用同步改写', () async {
    await writeEntry(DateTime(2026, 11, 3), '导出测试');
    final blob = await state.store.storeBytes(
      Uint8List.fromList(<int>[1, 2, 3]),
      '西湖.png',
    );
    state.attachmentRepo.insert(
      entryId: state.selected!.id,
      sha256: blob.sha256,
      filename: '西湖.png',
      mime: 'image/png',
      sizeBytes: 3,
    );
    state.entryRepo.saveContent(
      state.selected!.id,
      body: '图：![](assets/${blob.sha256}.png)',
    );
    await state.refresh();

    final dir = Directory(p.join(sandbox.path, 'export'))..createSync();
    final md = await state.markdownIo.exportEntry(state.selected!, dir.path);
    final name = '西湖-${blob.sha256.substring(0, 8)}.png';
    expect(File(p.join(dir.path, 'assets', name)).existsSync(), isTrue);
    expect(File(md).readAsStringSync(), contains('assets/$name'));
  }, skip: skip);

  test('失效的库记录会被过滤，也能手动移除', () async {
    final gone = p.join(sandbox.path, 'gone-library');
    Directory(gone).createSync(recursive: true);
    await AppPaths.adoptLibrary(gone);
    expect(
      AppPaths.loadRecentLibraries().any((item) => p.equals(item, gone)),
      isTrue,
    );

    // 目录被删掉后，记录会被自动过滤，不会出现"点进去才报错"
    Directory(gone).deleteSync(recursive: true);
    expect(
      AppPaths.loadRecentLibraries().any((item) => p.equals(item, gone)),
      isFalse,
    );

    // 手动移除
    final other = p.join(sandbox.path, 'other-library');
    Directory(other).createSync(recursive: true);
    await AppPaths.adoptLibrary(other);
    await AppPaths.removeRecentLibrary(other);
    expect(
      AppPaths.loadRecentLibraries().any((item) => p.equals(item, other)),
      isFalse,
    );
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
