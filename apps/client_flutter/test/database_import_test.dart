@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

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

/// 数据库目录 + 「导入数据库」：选中一个库覆盖当前库，先备份、失败回滚。
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
    sandbox = Directory.systemTemp.createTempSync('mdiary_import_');
    root = Directory(p.join(sandbox.path, 'data'))..createSync();
    Directory(p.join(root.path, 'db')).createSync();
    final db = AppDatabase.open(DataRootMigration.databaseFileIn(root.path));
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

  /// 在沙箱里造一个「别人的库」。
  String makeOtherDatabase(String fileName, {String title = '导入的'}) {
    final dir = Directory(p.join(sandbox.path, 'backup-$fileName'))
      ..createSync(recursive: true);
    final path = p.join(dir.path, fileName);
    final db = AppDatabase.open(path);
    EntryRepository(db).create(
      deviceId: 'other',
      date: DateTime(2026, 10, 1),
      title: title,
      body: '来自备份',
    );
    db.checkpoint();
    db.dispose();
    return path;
  }

  test('数据库落在数据目录的 db/ 子目录', () async {
    final live = File(DataRootMigration.databaseFileIn(root.path));
    expect(live.existsSync(), isTrue);
    expect(p.basename(live.parent.path), 'db');
  }, skip: skip);

  test('导入另一个库：覆盖当前库、先备份、导入后还能继续写', () async {
    final mine = await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '原来的', immediate: true);
    await state.flushNow();
    expect(state.entryRepo.count(), 1);
    expect(mine.id, isNotEmpty);

    final source = makeOtherDatabase('backup.sqlite');

    final result = await state.importDatabase(source);

    expect(result.entries, 1);
    expect(File(result.backup).existsSync(), isTrue, reason: '旧库要先备份');
    expect(state.entries.single.title, '导入的');
    expect(state.entryRepo.count(), 1);

    await state.createEntry();
    state.draftChanged(title: '导入之后', immediate: true);
    await state.flushNow();
    expect(state.entryRepo.count(), 2);
  }, skip: skip);

  test('不是数据库的文件被拒绝，当前库不受影响', () async {
    await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '别丢', immediate: true);
    await state.flushNow();

    final bad = File(p.join(sandbox.path, 'not-a-db.sqlite'))
      ..writeAsStringSync('this is not sqlite');

    await expectLater(
      state.importDatabase(bad.path),
      throwsA(isA<DataRootMigrationException>()),
    );

    expect(state.entryRepo.count(), 1);
    expect(state.entries.single.title, '别丢');
    expect(
      File(DataRootMigration.databaseFileIn(root.path)).existsSync(),
      isTrue,
    );
  }, skip: skip);

  test('来自更新版本的库被拒绝', () async {
    final dir = Directory(p.join(sandbox.path, 'future'))..createSync();
    final path = p.join(dir.path, 'future.sqlite');
    final db = AppDatabase.open(path);
    db.raw.execute('PRAGMA user_version = 99');
    db.dispose();

    await expectLater(
      state.importDatabase(path),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('更新的版本'),
        ),
      ),
    );
    expect(state.entryRepo.count(), 0);
  }, skip: skip);

  test('导入自己的库被拒绝', () async {
    await expectLater(
      state.importDatabase(DataRootMigration.databaseFileIn(root.path)),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('当前正在使用'),
        ),
      ),
    );
  }, skip: skip);

  test('老布局：根目录的 mdiary.sqlite 自动搬进 db/', () async {
    final legacyRoot = Directory(p.join(sandbox.path, 'legacy'))..createSync();
    File(p.join(legacyRoot.path, 'mdiary.sqlite'))
        .writeAsStringSync('legacy-db');
    File(p.join(legacyRoot.path, 'mdiary.sqlite-wal'))
        .writeAsStringSync('legacy-wal');

    AppPaths.adopt(
      DataRoot(path: legacyRoot.path, source: DataRootSource.userChosen),
    );
    AppPaths.migrateLegacyDatabaseLayout();

    expect(File(p.join(legacyRoot.path, 'mdiary.sqlite')).existsSync(), isFalse);
    expect(
      File(DataRootMigration.databaseFileIn(legacyRoot.path))
          .readAsStringSync(),
      'legacy-db',
    );
    expect(
      File('${DataRootMigration.databaseFileIn(legacyRoot.path)}-wal')
          .readAsStringSync(),
      'legacy-wal',
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
