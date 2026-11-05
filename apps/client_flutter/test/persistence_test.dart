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
import 'package:sqlite3/open.dart';

/// 文件级持久化：验证真实磁盘库（WAL）+ 附件库在「关闭 -> 重开」后仍然可用。
/// 之前的用例都用内存库，覆盖不到 WAL 落盘、user_version 幂等与附件引用还原。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory tempDir;
  late String dbPath;
  late AttachmentStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mdiary_persist_');
    dbPath = '${tempDir.path}/mdiary.sqlite';
    store = AttachmentStore(Directory('${tempDir.path}/attachments'));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('条目与附件在关闭重开后完整还原', () async {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    late String entryId;
    late String sha;

    // 第一次会话：写入
    var db = AppDatabase.open(dbPath);
    var entries = EntryRepository(db);
    var attachments = AttachmentRepository(db);
    final entry = entries.create(
      deviceId: 'dev-1',
      date: DateTime(2026, 11, 2),
      title: '磁盘持久化',
      body: '正文写入磁盘',
    );
    entryId = entry.id;
    final blob = await store.storeBytes(bytes, 'shot.png');
    sha = blob.sha256;
    attachments.insert(
      entryId: entry.id,
      sha256: sha,
      filename: 'shot.png',
      mime: 'image/png',
      sizeBytes: blob.sizeBytes,
    );
    db.dispose();

    expect(File(dbPath).existsSync(), isTrue, reason: '数据库文件应真实落盘');

    // 第二次会话：读取
    db = AppDatabase.open(dbPath);
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    final restored = entries.findById(entryId);
    expect(restored, isNotNull);
    expect(restored!.title, '磁盘持久化');
    expect(restored.bodyMd, '正文写入磁盘');

    final list = attachments.listByEntry(entryId);
    expect(list.length, 1);
    expect(list.single.sha256, sha);
    final localPath = store.pathFor(list.single.sha256, '.png');
    expect(localPath, isNotNull, reason: '附件文件应仍在磁盘上');
    expect(File(localPath!).readAsBytesSync(), bytes);
    db.dispose();
  }, skip: skip);

  test('重复打开同一个库是幂等的（迁移不会重复执行）', () {
    for (var i = 0; i < 3; i++) {
      final db = AppDatabase.open(dbPath);
      expect(
        db.raw.select('PRAGMA user_version').first['user_version'],
        AppDatabase.schemaVersion,
        reason: '第 ${i + 1} 次打开时 schema 版本应保持 ${AppDatabase.schemaVersion}',
      );
      final entries = EntryRepository(db);
      expect(entries.count(), i, reason: '不应因重开而丢数据或重复建表');
      entries.create(deviceId: 'dev', title: '第 $i 篇');
      db.dispose();
    }
  }, skip: skip);

  test('附件目录被同名文件占用时，写入失败且不留半成品', () async {
    // 在 attachments 位置放一个文件，模拟目录不可创建（类似只读/被占用）
    final blocked = File('${tempDir.path}/attachments')
      ..writeAsStringSync('not a directory');
    expect(blocked.existsSync(), isTrue);

    await expectLater(
      store.storeBytes(Uint8List.fromList(<int>[1, 2, 3]), 'a.png'),
      throwsA(anything),
    );

    // 没有产生任何附件记录的前提是：调用方拿到异常后不写库
    final db = AppDatabase.open(dbPath);
    final entries = EntryRepository(db);
    final attachments = AttachmentRepository(db);
    final entry = entries.create(deviceId: 'dev', title: '内容仍在');
    expect(attachments.listByEntry(entry.id), isEmpty);
    expect(entries.findById(entry.id)!.title, '内容仍在');
    db.dispose();
  }, skip: skip);

  test('删除条目并清理后，附件文件被回收但库记录一致', () async {
    final db = AppDatabase.open(dbPath);
    final entries = EntryRepository(db);
    final attachments = AttachmentRepository(db);
    final entry = entries.create(deviceId: 'dev', title: '待删');
    final blob = await store.storeBytes(
      Uint8List.fromList(<int>[9, 8, 7]),
      'x.bin',
    );
    attachments.insert(
      entryId: entry.id,
      sha256: blob.sha256,
      filename: 'x.bin',
      mime: 'application/octet-stream',
      sizeBytes: blob.sizeBytes,
    );

    attachments.deleteByEntry(entry.id);
    entries.purge(entry.id);
    final removed = await store.collectGarbage(attachments.referencedHashes());

    expect(removed, 1);
    expect(store.pathFor(blob.sha256, '.bin'), isNull);
    expect(entries.count(), 0);
    db.dispose();
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
