@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/app_paths.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/data_root_migration.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 多库：默认目录、切换（空目录新建）、导入为新库、按 id 合并。
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
    sandbox = Directory.systemTemp.createTempSync('mdiary_library_');
    root = Directory(p.join(sandbox.path, 'data'))..createSync();
    Directory(p.join(root.path, 'db')).createSync(recursive: true);
    AppPaths.adopt(
      DataRoot(path: root.path, source: DataRootSource.userChosen),
    );
    // AppPaths 是全局的：每个用例都把当前库复位到新的默认目录，避免串味
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
      store: store,
      markdownIo: MarkdownIo(
        entries: entryRepo,
        attachments: attachmentRepo,
        store: store,
      ),
      filePicker: () async => null,
      directoryPicker: (title) async => null,
      dataRootPath: root.path,
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  /// 造一个外部库，返回它的路径。
  String makeExternalDatabase(
    String folder, {
    String title = '外部库',
    String? id,
    DateTime? updatedAt,
  }) {
    final dir = Directory(p.join(sandbox.path, folder))..createSync();
    final path = p.join(dir.path, 'other.sqlite');
    final db = AppDatabase.open(path);
    final entries = EntryRepository(db);
    final now = DateTime.now();
    if (id == null) {
      entries.create(
        deviceId: 'x',
        date: DateTime(2026, 10, 1),
        title: title,
        body: '来自外部库',
      );
    } else {
      db.raw.execute(
        'INSERT INTO entries '
        '(id, title, body_md, entry_date, created_at, updated_at, rev, pinned, device_id, deleted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, 2, 0, ?, NULL)',
        <Object?>[
          id,
          title,
          '外部库的新版本',
          DateTime(2026, 10, 1).millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
          (updatedAt ?? now).millisecondsSinceEpoch,
          'x',
        ],
      );
    }
    db.checkpoint();
    db.dispose();
    return path;
  }

  test('默认库在 <数据目录>/db 下', () {
    expect(p.equals(AppPaths.libraryDir, p.join(root.path, 'db')), isTrue);
    expect(File(AppPaths.databaseFile).existsSync(), isTrue);
    expect(p.basename(p.dirname(AppPaths.databaseFile)), 'db');
  }, skip: skip);

  test('切到空目录会新建空库，切回来数据还在', () async {
    await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '第一个库', immediate: true);
    await state.flushNow();
    expect(state.entryRepo.count(), 1);
    final firstDir = AppPaths.libraryDir;

    final emptyDir = p.join(sandbox.path, '库-张三');
    await state.switchLibrary(emptyDir);

    expect(AppPaths.libraryDir, p.canonicalize(emptyDir));
    expect(state.entryRepo.count(), 0, reason: '新库是空的');
    expect(File(p.join(emptyDir, 'mdiary.sqlite')).existsSync(), isTrue);
    expect(state.recentLibraries, contains(p.canonicalize(emptyDir)));

    await state.switchLibrary(firstDir);
    expect(state.entryRepo.count(), 1);
    expect(state.entries.single.title, '第一个库');
  }, skip: skip);

  test('导入新库：复制到 libraries/<名字> 并切过去', () async {
    final external = makeExternalDatabase('ext', title: '外来的日记');

    final newDir = await state.importDatabaseAsLibrary(
      external,
      folderName: '家庭',
    );

    expect(p.basename(newDir), '家庭');
    expect(p.dirname(newDir), p.join(AppPaths.root.path, 'libraries'));
    expect(File(p.join(newDir, 'mdiary.sqlite')).existsSync(), isTrue);
    expect(AppPaths.libraryDir, p.canonicalize(newDir));
    expect(state.entryRepo.count(), 1);
    expect(state.entries.single.title, '外来的日记');
    expect(File(external).existsSync(), isTrue, reason: '源文件不动');
  }, skip: skip);

  test('合并库：同 id 保留较新的，新条目追加，附件按 sha 去重', () async {
    // 当前库：一篇日记 + 一个附件
    final mine = await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '旧标题', body: '旧正文', immediate: true);
    await state.flushNow();
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final blob = await state.store.storeBytes(bytes, 'shot.png');
    state.attachmentRepo.insert(
      entryId: mine.id,
      sha256: blob.sha256,
      filename: 'shot.png',
      mime: 'image/png',
      sizeBytes: bytes.length,
    );
    expect(state.attachmentRepo.blobCount(), 1);

    // 外部库：同 id 的更新版本 + 一个新条目 + 同一个附件（同 sha）
    final external = makeExternalDatabase(
      'merge',
      id: mine.id,
      title: '新标题',
      updatedAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    final externalDb = AppDatabase.open(external);
    final externalEntries = EntryRepository(externalDb);
    final extra = externalEntries.create(
      deviceId: 'x',
      date: DateTime(2026, 9, 9),
      title: '外部新增',
      body: '外来条目',
    );
    AttachmentRepository(externalDb).insert(
      entryId: extra.id,
      sha256: blob.sha256,
      filename: 'shot.png',
      mime: 'image/png',
      sizeBytes: bytes.length,
    );
    AttachmentRepository(externalDb).putBlob(blob.sha256, bytes);
    externalDb.checkpoint();
    externalDb.dispose();

    final result = await state.mergeLibrary(external);

    expect(result.added, 1, reason: '只新增「外部新增」');
    expect(result.updated, 1, reason: '同 id 被较新的覆盖');
    expect(state.entryRepo.count(), 2);
    expect(state.entryRepo.findById(mine.id)!.title, '新标题');
    expect(
      state.attachmentRepo.blobCount(),
      1,
      reason: '同一个附件按 sha 去重，不重复存字节',
    );
    expect(result.blobsAdded, 0);
  }, skip: skip);

  test('合并自己会被拒绝', () async {
    await expectLater(
      state.mergeLibrary(AppPaths.databaseFile),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('自己'),
        ),
      ),
    );
  }, skip: skip);

  test('切到不是库的目录会报错并留在原库', () async {
    final broken = Directory(p.join(sandbox.path, 'broken'))..createSync();
    File(p.join(broken.path, 'mdiary.sqlite')).writeAsStringSync('not sqlite');

    await expectLater(
      state.switchLibrary(broken.path),
      throwsA(isA<DataRootMigrationException>()),
    );
    expect(p.equals(AppPaths.libraryDir, p.join(root.path, 'db')), isTrue);
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
