@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// v2：附件字节存进数据库（按 sha256 去重），磁盘目录只是可重建的缓存。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory tempDir;
  late AppDatabase db;
  late AttachmentRepository attachments;
  late AttachmentStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mdiary_blob_');
    db = AppDatabase.inMemory();
    attachments = AttachmentRepository(db);
    store = AttachmentStore(
      Directory(p.join(tempDir.path, 'attachments')),
      blobs: attachments,
    );
  });

  tearDown(() {
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('字节进数据库，删掉磁盘缓存也能重建', () async {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final stored = await store.storeBytes(bytes, 'a.png');

    expect(attachments.readBlob(stored.sha256), bytes);
    expect(attachments.hasBlob(stored.sha256), isTrue);

    File(stored.path).deleteSync();
    final restored = store.pathFor(stored.sha256, '.png');
    expect(restored, isNotNull, reason: '库里还有字节，缓存应该能重建');
    expect(File(restored!).readAsBytesSync(), bytes);
  }, skip: skip);

  test('同一内容多次插入只占一份字节', () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final first = await store.storeBytes(bytes, 'x.png');
    final second = await store.storeBytes(bytes, 'y.png');

    expect(first.sha256, second.sha256);
    expect(attachments.blobCount(), 1);
  }, skip: skip);

  test('老数据升级：磁盘文件回填进数据库（幂等）', () async {
    final bytes = Uint8List.fromList(<int>[9, 8, 7]);
    final digest = sha256.convert(bytes).toString();
    final folder = Directory(
      p.join(tempDir.path, 'attachments', digest.substring(0, 2)),
    )..createSync(recursive: true);
    File(p.join(folder.path, '$digest.png')).writeAsBytesSync(bytes);
    final entry = EntryRepository(db).create(deviceId: 'd', title: '老数据');
    attachments.insert(
      entryId: entry.id,
      sha256: digest,
      filename: 'old.png',
      mime: 'image/png',
      sizeBytes: bytes.length,
    );
    expect(attachments.hasBlob(digest), isFalse);

    final imported = await store.backfillFromFiles();

    expect(imported, 1);
    expect(attachments.readBlob(digest), bytes);
    expect(await store.backfillFromFiles(), 0, reason: '第二次不应重复搬');
  }, skip: skip);

  test('GC 同时清掉库里的孤儿字节和磁盘缓存', () async {
    final entries = EntryRepository(db);
    final entry = entries.create(deviceId: 'd', title: '留着');
    final kept = await store.storeBytes(Uint8List.fromList(<int>[1]), 'keep.png');
    attachments.insert(
      entryId: entry.id,
      sha256: kept.sha256,
      filename: 'keep.png',
      mime: 'image/png',
      sizeBytes: 1,
    );
    final orphan = await store.storeBytes(
      Uint8List.fromList(<int>[2]),
      'orphan.png',
    );
    expect(attachments.blobCount(), 2);

    final removed = await store.collectGarbage(<String>{kept.sha256});

    expect(removed, greaterThanOrEqualTo(1));
    expect(attachments.hasBlob(orphan.sha256), isFalse);
    expect(attachments.hasBlob(kept.sha256), isTrue);
    expect(store.pathFor(orphan.sha256, '.png'), isNull);
  }, skip: skip);

  test('导出按原来的文件形式写回 assets/（源是数据库）', () async {
    final entries = EntryRepository(db);
    final io = MarkdownIo(
      entries: entries,
      attachments: attachments,
      store: store,
    );
    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 5),
      title: '带附件',
      body: '正文',
    );
    final bytes = Uint8List.fromList(<int>[4, 5, 6, 7]);
    final stored = await store.storeBytes(bytes, 'shot.png');
    attachments.insert(
      entryId: entry.id,
      sha256: stored.sha256,
      filename: 'shot.png',
      mime: 'image/png',
      sizeBytes: bytes.length,
    );
    // 模拟用户手删了缓存：导出必须仍然成功
    File(stored.path).deleteSync();
    entries.saveContent(
      entry.id,
      body: '正文\n\n![shot.png](assets/${stored.sha256}.png)',
    );

    final out = Directory(p.join(tempDir.path, 'out'))..createSync();
    final fresh = entries.findById(entry.id)!;
    final exported = await io.exportEntry(fresh, out.path);

    final asset = File(
      p.join(out.path, 'assets', '${stored.sha256}.png'),
    );
    expect(asset.existsSync(), isTrue);
    expect(asset.readAsBytesSync(), bytes);
    expect(File(exported).readAsStringSync(), contains('assets/'));
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
