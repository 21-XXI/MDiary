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

/// v1.1 的几项收尾：清空回收站、导出已删条目不产幽灵文件、导入 .md 体积上限。
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
    tempDir = Directory.systemTemp.createTempSync('mdiary_v11_');
    db = AppDatabase.inMemory();
    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final store = AttachmentStore(
      Directory('${tempDir.path}/attachments'),
      blobs: attachmentRepo,
    );
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
      directoryPicker: (title) async => tempDir.path,
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('清空回收站：日记和没有引用的附件字节一起清掉', () async {
    final keep = await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '要留的', immediate: true);
    await state.flushNow();
    final gone = await state.selectDay(DateTime(2026, 11, 2));
    state.draftChanged(title: '要删的', immediate: true);
    await state.flushNow();
    final bytes = await state.store.storeBytes(
      Uint8List.fromList(<int>[1, 2, 3]),
      'shot.png',
    );
    state.attachmentRepo.insert(
      entryId: gone.id,
      sha256: bytes.sha256,
      filename: 'shot.png',
      mime: 'image/png',
      sizeBytes: 3,
    );
    expect(state.attachmentRepo.blobCount(), 1);

    state.entryRepo.softDelete(gone.id);
    await state.refresh();
    expect(state.trashCount, 1);

    final removed = await state.purgeAllDeleted();

    expect(removed, 1);
    expect(state.trashCount, 0);
    expect(state.entryRepo.findById(gone.id), isNull);
    expect(state.entryRepo.findById(keep.id), isNotNull);
    expect(
      state.attachmentRepo.blobCount(),
      0,
      reason: '没有引用的附件字节也要一起回收',
    );
  }, skip: skip);

  test('导出已删除的日记：报错而不是写幽灵文件', () async {
    final entry = await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '会被删掉', immediate: true);
    await state.flushNow();
    state.entryRepo.softDelete(entry.id);
    await state.refresh();

    await expectLater(
      state.exportCurrent(entry),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('已被删除'),
        ),
      ),
    );
  }, skip: skip);

  test('导入 .md 有单文件上限（> 10 MB 跳过并记错误）', () async {
    final dir = Directory('${tempDir.path}/import')..createSync();
    final big = File('${dir.path}/big.md');
    // 10 MB + 1 字节的正文，不含 front matter
    big.writeAsStringSync('x' * (MarkdownIo.maxMarkdownBytes + 1));
    File('${dir.path}/small.md')
        .writeAsStringSync('---\ntitle: 小文件\ndate: 2026-11-01\n---\n\n正文');

    final result = await state.markdownIo.importDirectory(
      dir.path,
      deviceId: 'd',
    );

    expect(result.imported, 1);
    expect(result.errors, hasLength(1));
    expect(result.errors.single, contains('超过 10 MB'));
    expect(state.entryRepo.count(), 1);
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
