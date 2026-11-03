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

/// 粘贴截图：剪贴板有图就落盘 + 写库 + 返回附件；没有就返回 null，什么都不写。
/// 真实读取由 Windows runner 完成（GDI+ 编码 PNG），这里注入 reader 测逻辑。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory tempDir;
  late AppDatabase db;
  late AppState state;

  AppState buildState({required Uint8List? clipboard}) {
    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final store = AttachmentStore(Directory('${tempDir.path}/attachments'));
    return AppState(
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
      clipboardImageReader: () async => clipboard,
    );
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mdiary_paste_');
    db = AppDatabase.inMemory();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    db.dispose();
  });

  test('剪贴板有图片：落成 PNG 附件，文件名带时间戳', () async {
    // 任意字节即可：这里只验证「字节被当作图片附件存下来」，
    // PNG 解码由真实的 runner + Image.file 负责。
    final bytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    state = buildState(clipboard: bytes);
    await state.bootstrap();
    final entry = await state.selectDay(DateTime(2026, 11, 3));

    final attached = await state.pasteClipboardImage(entry);

    expect(attached, isNotNull);
    expect(attached!.attachment.filename, startsWith('截图-'));
    expect(attached.attachment.filename, endsWith('.png'));
    expect(attached.isImage, isTrue);
    expect(state.attachmentRepo.listByEntry(entry.id), hasLength(1));
    final path = state.store.pathFor(attached.blob.sha256, '.png');
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), bytes);
    state.dispose();
  }, skip: skip);

  test('剪贴板没有图片：返回 null，不写库也不落盘', () async {
    state = buildState(clipboard: null);
    await state.bootstrap();
    final entry = await state.selectDay(DateTime(2026, 11, 3));

    final attached = await state.pasteClipboardImage(entry);

    expect(attached, isNull);
    expect(state.attachmentRepo.countsByEntry(), isEmpty);
    final dir = Directory('${tempDir.path}/attachments');
    expect(dir.existsSync(), isFalse, reason: '没有图片时连目录都不该建');
    state.dispose();
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
