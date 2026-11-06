@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/app.dart';
import 'package:mdiary/core/app_paths.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/features/rag_page.dart';
import 'package:mdiary/rag/answer.dart';
import 'package:mdiary/rag/embedder.dart';
import 'package:mdiary/rag/skill_job.dart';
import 'package:mdiary/rag/summarizer.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 2.0.7：RAG 独立界面（问答检索 / 日报 / 档案）。
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
    sandbox = Directory.systemTemp.createTempSync('mdiary_ragui_');
    root = Directory(p.join(sandbox.path, 'data'))..createSync();
    Directory(p.join(root.path, 'db')).createSync(recursive: true);
    AppPaths.adopt(
      DataRoot(path: root.path, source: DataRootSource.userChosen),
    );
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
      tagRepository: TagRepository(db),
      store: store,
      markdownIo: MarkdownIo(
        entries: entryRepo,
        attachments: attachmentRepo,
        store: store,
        tags: TagRepository(db),
      ),
      filePicker: () async => null,
      directoryPicker: (title) async => null,
      dataRootPath: root.path,
      ragEmbedder: HashingEmbedder(dimension: 64),
      ragSummarizerOverride: FakeSummarizer(),
      ragAnswererOverride: FakeAnswerer(),
      skillDistillerOverride: FakeSkillDistiller(),
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    state.db.dispose();
    if (sandbox.existsSync()) {
      try {
        sandbox.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶尔还有句柄未释放：交给系统临时目录清理
      }
    }
  });

  Future<void> seed() async {
    await state.selectDay(DateTime(2026, 11, 1));
    state.draftChanged(title: '杭州', body: '去了西湖，风很大。', immediate: true);
    await state.flushNow();
    await state.selectDay(DateTime(2026, 11, 2));
    state.draftChanged(title: '工作', body: '和产品对排期。', immediate: true);
    await state.flushNow();
    await state.reindexRag();
  }

  testWidgets('导航栏进入 RAG：三个页签、检索命中、点日记回到主界面', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seed();
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('RAG（问答 / 日报 / 档案）'));
    await tester.pumpAndSettle();
    expect(find.byType(RagPage), findsOneWidget);
    expect(find.text('问答'), findsOneWidget);
    expect(find.text('日报'), findsOneWidget);
    expect(find.text('档案'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '西湖');
    await tester.tap(find.widgetWithText(FilledButton, '检索'));
    await tester.pumpAndSettle();
    expect(find.textContaining('杭州'), findsWidgets);

    await tester.tap(
      find
          .descendant(
            of: find.byType(RagPage),
            matching: find.byType(ListTile),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(RagPage), findsNothing, reason: '应回到主界面');
    expect(state.selected?.title, '杭州');
  }, skip: skip);

  testWidgets('问答页：检索后可以生成带引用的流式回答', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seed();
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('RAG（问答 / 日报 / 档案）'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '西湖');
    await tester.tap(find.widgetWithText(FilledButton, '检索'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '生成回答'));
    await tester.pumpAndSettle();

    expect(find.textContaining('根据记录'), findsWidgets);
    expect(find.textContaining('[2026-11-01-杭州]'), findsWidgets);
    expect(find.textContaining('本地 '), findsWidgets, reason: '应标注模型来源');
    expect(find.textContaining('索引：'), findsWidgets, reason: '应显示索引状态');

    await tester.tap(find.widgetWithText(TextButton, '新对话'));
    await tester.pumpAndSettle();
    expect(find.textContaining('根据记录'), findsNothing, reason: '新对话应清空回答');
  }, skip: skip);

  testWidgets('蒸馏页：开关 + 立即蒸馏 + 列表', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seed();
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('蒸馏（skill）'));
    await tester.pumpAndSettle();

    expect(find.text('启用蒸馏'), findsOneWidget);
    await tester.tap(find.text('启用蒸馏'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '立即蒸馏'));
    await tester.pumpAndSettle();

    expect(find.text('SKILL.md'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(ListTile),
      ),
      findsWidgets,
      reason: '生成后应出现在列表里',
    );
  }, skip: skip);

  testWidgets('日报页：补全后能看到日报并渲染内容', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seed();
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('RAG（问答 / 日报 / 档案）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日报'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '补全缺失'));
    await tester.pumpAndSettle();

    expect(find.textContaining('共'), findsWidgets);
    expect(find.textContaining('日报'), findsWidgets);
  }, skip: skip);

  testWidgets('档案页：生成后展示 soul 内容', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seed();
    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('RAG（问答 / 日报 / 档案）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('档案'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '重新生成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Soul'), findsWidgets);
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
