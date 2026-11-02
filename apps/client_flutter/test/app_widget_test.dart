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
import 'package:mdiary/state/app_state.dart';
import 'package:mdiary/ui/markdown_view.dart';
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

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mdiary_ui_');
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
      markdownIo: MarkdownIo(entries: entryRepo, attachments: attachmentRepo, store: store),
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

  testWidgets('新建 -> 输入 -> 800ms 后自动落库', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);

    expect(state.selected, isNotNull);
    expect(state.entryRepo.count(), 1);

    await tester.enterText(find.byKey(const Key('editor-title')), '杭州三日');
    await tester.enterText(find.byKey(const Key('editor-body')), '# 第一天\n西湖下雨。');
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
    await tester.enterText(find.byKey(const Key('editor-body')), '**粗体** 与 `代码`');
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
