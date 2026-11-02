@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/app.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:sqlite3/open.dart';

/// 布局回归：不同窗口尺寸下不应出现 RenderFlex 溢出。
/// Flutter 在溢出时会抛 FlutterError，测试里用 takeException 断言即可。
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
    tempDir = Directory.systemTemp.createTempSync('mdiary_layout_');
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

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
  }

  for (final size in <Size>[
    const Size(800, 600), // 小窗
    const Size(1024, 720), // 常见笔记本
    const Size(1440, 900), // 桌面
  ]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}：首页与编辑器无溢出', (tester) async {
      await pumpAt(tester, size);
      expect(tester.takeException(), isNull, reason: '首页在 ${size.width.toInt()} 宽下溢出');

      // 新建并进入编辑器
      final newButton = find.widgetWithText(FilledButton, '新建日记');
      await tester.tap(newButton.first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '编辑器在 ${size.width.toInt()} 宽下溢出');

      // 三种视图模式都过一遍
      for (final mode in <String>['分栏', '预览', '编辑']) {
        await tester.tap(find.text(mode));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '$mode 模式在 ${size.width.toInt()} 宽下溢出',
        );
      }
    }, skip: skip);
  }

  testWidgets('窗口从宽变窄再变宽，布局可恢复且无溢出', (tester) async {
    await pumpAt(tester, const Size(1440, 900));
    await tester.tap(find.widgetWithText(FilledButton, '新建日记').first);
    await tester.pumpAndSettle();

    for (final size in <Size>[
      const Size(700, 560),
      const Size(1200, 800),
      const Size(640, 520),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '动态调整到 ${size.width.toInt()}x${size.height.toInt()} 时溢出',
      );
    }
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
