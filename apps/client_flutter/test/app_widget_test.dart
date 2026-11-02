@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/app.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/features/settings_page.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:mdiary/ui/markdown_view.dart';
import 'package:mdiary/ui/widgets.dart';
import 'package:sqlite3/open.dart';

/// 界面级 widget 测试（无头）：自动保存、预览切换、快捷键、搜索。
/// 与 data_layer_test 一样需要 sqlite3.dll，缺失时整组跳过。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skipWidgetTests = dll == null;

  late Directory tempDir;
  late AppDatabase db;
  late AppState state;

  // 注入给 AppState 的假对话框：测试里直接指定返回值
  String? nextDirectory;
  PickedFile? nextPickedFile;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mdiary_ui_');
    db = AppDatabase.inMemory();
    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final store = AttachmentStore(Directory('${tempDir.path}/attachments'));
    nextDirectory = null;
    nextPickedFile = null;
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
      filePicker: () async => nextPickedFile,
      directoryPicker: (title) async => nextDirectory,
      dataRootPath: tempDir.path,
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
  }

  Future<void> createEntry(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '新建日记').first);
    await tester.pumpAndSettle();
  }

  /// 等待真实的异步 IO（文件读写）完成：pumpAndSettle 只推进帧，不会等待 Future。
  Future<void> settleAsync(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
  }

  /// 触发真实文件 IO 的点击必须在 runAsync 中执行，
  /// 否则 fake-async 区里 `File.writeAsBytes` 的 Future 永远不会完成。
  Future<void> tapAsync(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('新建 -> 输入 -> 800ms 后自动落库', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);

    expect(state.selected, isNotNull);
    expect(state.entryRepo.count(), 1);

    await tester.enterText(find.byKey(const Key('editor-title')), '杭州三日');
    await tester.enterText(
      find.byKey(const Key('editor-body')),
      '# 第一天\n西湖下雨。',
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 防抖未到时不应写入
    var saved = state.entryRepo.findById(state.selected!.id)!;
    expect(saved.title, isEmpty);

    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    saved = state.entryRepo.findById(state.selected!.id)!;
    expect(saved.title, '杭州三日');
    expect(saved.bodyMd, contains('西湖下雨'));
    expect(saved.rev, greaterThan(1));
  }, skip: skipWidgetTests);

  testWidgets('切换预览后渲染 Markdown', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    await tester.enterText(
      find.byKey(const Key('editor-body')),
      '**粗体** 与 `代码`',
    );
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownView), findsOneWidget);
    expect(find.textContaining('粗体'), findsWidgets);
  }, skip: skipWidgetTests);

  testWidgets('Ctrl+N 新建第二篇，列表与库同步', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    // 先写入内容，避免第一篇作为「空草稿」在切换时被清理
    await tester.enterText(find.byKey(const Key('editor-body')), '第一篇的内容');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    expect(state.entryRepo.count(), 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    // 新草稿还没输入内容，此时库里仍是 1 篇，但列表里已经多出一条空草稿
    expect(state.selected, isNotNull);
    expect(state.selected!.bodyMd, isEmpty);
    expect(state.entries.length, 2);

    await tester.enterText(find.byKey(const Key('editor-body')), '第二篇');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    expect(state.entryRepo.count(), 2);
  }, skip: skipWidgetTests);

  testWidgets('搜索按中文子串过滤，清空后恢复', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    await tester.enterText(find.byKey(const Key('editor-body')), '龙井村喝茶');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    final searchField = find.widgetWithText(TextField, '搜索标题或正文（Ctrl+F）');
    await tester.enterText(searchField, '龙井');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(state.entries.length, 1);

    await tester.enterText(searchField, '不存在的内容');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(state.entries, isEmpty);
    expect(find.text('没有匹配的日记'), findsOneWidget);

    await tester.enterText(searchField, '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(state.entries.length, 1);
  }, skip: skipWidgetTests);

  testWidgets('空草稿在切换条目时被清理', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    await tester.enterText(find.byKey(const Key('editor-body')), '有内容的日记');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    final firstId = state.selected!.id;

    await createEntry(tester);
    expect(state.entryRepo.count(), 2);

    // 新建的空草稿没有输入，切回第一篇后应被物理删除
    await tester.tap(find.textContaining('有内容的日记').first);
    await tester.pumpAndSettle();
    expect(state.entryRepo.count(), 1);
    expect(state.entryRepo.findById(firstId), isNotNull);
  }, skip: skipWidgetTests);

  testWidgets('工具栏导出按钮生成 .md 文件', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    await tester.enterText(find.byKey(const Key('editor-title')), '导出一篇');
    await tester.enterText(find.byKey(const Key('editor-body')), '正文内容');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    final outDir = Directory('${tempDir.path}/export')..createSync();
    nextDirectory = outDir.path;
    await tapAsync(tester, find.byTooltip('导出为 .md'));

    final files = outDir.listSync().whereType<File>().toList();
    expect(files.length, 1);
    expect(files.first.path, endsWith('.md'));
    expect(files.first.readAsStringSync(), contains('导出一篇'));
  }, skip: skipWidgetTests);

  testWidgets('插入附件：写库、落盘并插入正文引用', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    nextPickedFile = PickedFile(name: 'shot.png', bytes: _tinyPng);

    await tapAsync(tester, find.byTooltip('插入附件（≤ 25 MB）'));
    await tester.pump(const Duration(milliseconds: 900));
    await settleAsync(tester);

    final entry = state.selected!;
    expect(entry.bodyMd, contains('![](assets/'));
    expect(entry.bodyMd, contains('.png'));
    expect(state.attachmentCountOf(entry.id), 1);
    final archiveFiles = Directory('${tempDir.path}/attachments')
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(archiveFiles.length, 1, reason: '附件应按内容哈希落盘');
  }, skip: skipWidgetTests);

  testWidgets('设置页整库导出 + 从目录导入', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
    await createEntry(tester);
    await tester.enterText(find.byKey(const Key('editor-title')), '第一篇');
    await tester.enterText(find.byKey(const Key('editor-body')), '内容一');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    // 整库导出
    final libDir = Directory('${tempDir.path}/lib_out')..createSync();
    nextDirectory = libDir.path;
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    final settingsScrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('整库导出'),
      200,
      scrollable: settingsScrollable,
    );
    await tapAsync(tester, find.text('整库导出'));
    expect(libDir.listSync().whereType<File>().length, 1);
    // 从目录导入一个外部 .md
    final importDir = Directory('${tempDir.path}/in_dir')..createSync();
    File('${importDir.path}/外部.md')
        .writeAsStringSync('---\ntitle: 外部导入\ndate: 2026-05-01\n---\n\n导入的正文');
    nextDirectory = importDir.path;
    await tester.scrollUntilVisible(
      find.text('从目录导入 .md'),
      200,
      scrollable: settingsScrollable,
    );
    await tapAsync(tester, find.text('从目录导入 .md'));

    expect(state.entryRepo.count(), 2);
    expect(state.entries.any((entry) => entry.title == '外部导入'), isTrue);

    // SnackBar 的计时器是在 runAsync 的真实时钟里创建的：必须用真实等待放掉，
    // 否则测试结束、Widget 树销毁后回调会触发 "mounted is not true" 断言。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
  }, skip: skipWidgetTests);

  testWidgets('1000 篇时列表惰性构建（首屏只建可见项）', (tester) async {
    db.raw.execute('BEGIN');
    for (var i = 0; i < 1000; i++) {
      state.entryRepo.create(
        deviceId: 'perf',
        date: DateTime(2024, 1, 1).add(Duration(days: i)),
        title: '第 $i 篇',
        body: '第 $i 篇的正文内容',
      );
    }
    db.raw.execute('COMMIT');
    await state.refresh();

    final watch = Stopwatch()..start();
    await pumpApp(tester);
    watch.stop();

    final tiles = find.byType(EntryListTile).evaluate().length;
    debugPrint(
      'LIST1000 firstFrame=${watch.elapsedMilliseconds}ms tiles=$tiles entries=${state.entries.length}',
    );

    expect(state.entries.length, 1000);
    expect(tiles, greaterThan(0));
    // 惰性构建：不应把 1000 条全建出来（视口 + cacheExtent 内通常十几到几十条）
    expect(tiles, lessThan(60), reason: '列表应惰性构建，而不是一次渲染全部 1000 条');
  }, skip: skipWidgetTests);
}

// 1x1 透明 PNG：足够走通「图片附件」的完整链路
final Uint8List _tinyPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

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
