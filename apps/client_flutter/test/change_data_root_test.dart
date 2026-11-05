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

/// 运行中切换数据目录：条目/附件要跟过去，位置要记住，旧目录要清掉；
/// 失败时必须原地回滚，不能丢稿。需要真实 sqlite3.dll，缺失时整组跳过。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory sandbox;
  late Directory oldRoot;
  late Directory newRoot;
  late AppState state;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('mdiary_switch_');
    oldRoot = Directory(p.join(sandbox.path, 'old'))..createSync();
    newRoot = Directory(p.join(sandbox.path, 'new'));

    Directory(p.join(oldRoot.path, 'db')).createSync(recursive: true);
    final db = AppDatabase.open(
      DataRootMigration.databaseFileIn(oldRoot.path),
    );
    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final store = AttachmentStore(
      Directory(p.join(oldRoot.path, 'attachments')),
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
      directoryPicker: (title) async => newRoot.path,
      dataRootPath: oldRoot.path,
    );
    // 位置指针写到沙箱里，别碰真实 exe 目录
    AppPaths.locationStore = DataLocationStore(sandbox.path);
    await state.bootstrap();
  });

  tearDown(() {
    state.db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('迁移后条目与附件都在新目录，旧目录被删掉', () async {
    await state.createEntry();
    state.draftChanged(title: '搬家测试', body: '正文内容', immediate: true);
    await state.flushNow();
    File(p.join(oldRoot.path, 'attachments', 'ab', 'deadbeef.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);

    final result = await state.changeDataRoot(newRoot.path);

    final target = p.canonicalize(newRoot.path);
    expect(result.target, target);
    expect(result.files, greaterThanOrEqualTo(2), reason: '库 + 附件');
    expect(state.dataRootPath, target);
    expect(File(DataRootMigration.databaseFileIn(target)).existsSync(), isTrue);
    expect(state.entryRepo.count(), 1);
    expect(state.entries.single.title, '搬家测试');
    expect(
      File(p.join(target, 'attachments', 'ab', 'deadbeef.png')).existsSync(),
      isTrue,
    );
    expect(state.attachmentsPath, p.join(target, 'attachments'));
    expect(oldRoot.existsSync(), isFalse, reason: '迁移成功后旧目录应被删除');
    expect(
      File(p.join(sandbox.path, AppPaths.locationFileName)).readAsStringSync(),
      target,
      reason: '位置指针要指向新目录',
    );
    expect(AppPaths.root.path, target);

    // 换库后还能继续写
    await state.createEntry();
    state.draftChanged(title: '搬家后继续写', immediate: true);
    await state.flushNow();
    expect(state.entryRepo.count(), 2);
  }, skip: skip);

  test('目标目录不可用时抛错，数据与状态都留在旧目录', () async {
    await state.createEntry();
    state.draftChanged(title: '不该丢', body: '原稿', immediate: true);
    await state.flushNow();

    Directory(newRoot.path).createSync();
    File(p.join(newRoot.path, 'x.txt')).writeAsStringSync('不属于 MDiary');

    await expectLater(
      state.changeDataRoot(newRoot.path),
      throwsA(isA<DataRootMigrationException>()),
    );

    expect(state.dataRootPath, oldRoot.path);
    expect(state.entryRepo.count(), 1);
    expect(state.entries.single.title, '不该丢');
    expect(
      File(DataRootMigration.databaseFileIn(oldRoot.path)).existsSync(),
      isTrue,
      reason: '回滚后旧库必须还在',
    );

    // 回滚之后还能正常继续编辑
    await state.createEntry();
    state.draftChanged(title: '回滚后继续写', immediate: true);
    await state.flushNow();
    expect(state.entryRepo.count(), 2);
  }, skip: skip);

  test('切到同一个目录直接拒绝，不动数据', () async {
    await expectLater(
      state.changeDataRoot(oldRoot.path),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('这已经是当前数据目录'),
        ),
      ),
    );
    expect(state.dataRootPath, oldRoot.path);
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
