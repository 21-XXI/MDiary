@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' show AppExitResponse;

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
import 'package:mdiary/data/models.dart';
import 'package:mdiary/features/settings_page.dart';
import 'package:mdiary/features/star_map/star_map_layout.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:mdiary/ui/markdown_view.dart';
import 'package:mdiary/ui/month_calendar.dart';
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

  testWidgets('关窗请求会强制落库（最后 0.8s 输入不丢）', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    await tester.enterText(find.byKey(const Key('editor-title')), '关窗前输入');
    await tester.enterText(find.byKey(const Key('editor-body')), '还没到 800ms');
    await tester.pump(const Duration(milliseconds: 200));

    // 防抖还没触发，数据库里仍是空的
    final entryId = state.selected!.id;
    expect(state.entryRepo.findById(entryId)!.title, isEmpty);

    final response = await tester.binding.handleRequestAppExit();
    expect(response, AppExitResponse.exit);
    await tester.pumpAndSettle();

    final saved = state.entryRepo.findById(entryId)!;
    expect(saved.title, '关窗前输入');
    expect(saved.bodyMd, '还没到 800ms');
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

    final searchField = find.widgetWithText(TextField, '搜索标题、正文或标签（Ctrl+F）');
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

  testWidgets('超过 25 MB 的附件被拒绝，且不写库', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    // 26 MB 全零字节，仅用于触发上限判断（不会真的写盘）
    nextPickedFile = PickedFile(
      name: 'huge.bin',
      bytes: Uint8List(26 * 1024 * 1024),
    );

    await tapAsync(tester, find.byTooltip('插入附件（≤ 25 MB）'));
    await tester.pumpAndSettle();

    final entry = state.selected!;
    expect(entry.bodyMd, isEmpty, reason: '被拒绝时不应插入引用');
    expect(state.attachmentCountOf(entry.id), 0, reason: '被拒绝时不应写附件表');
    // 附件目录可能压根没被创建（更彻底），存在时也不应有文件
    final archiveDir = Directory('${tempDir.path}/attachments');
    final archiveFiles = archiveDir.existsSync()
        ? archiveDir.listSync(recursive: true).whereType<File>().toList()
        : <File>[];
    expect(archiveFiles.length, 0, reason: '被拒绝时不应落盘');
    expect(find.textContaining('添加附件失败'), findsOneWidget);
  }, skip: skipWidgetTests);

  testWidgets('10,000 字长文：保存、重载与预览均正常', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);
    final longBody = List<String>.generate(
      400,
      (i) => '第 $i 段：这是一段用于模拟长文的文字，包含中文与 English 混排。',
    ).join('\n');
    expect(longBody.length, greaterThan(10000));

    await tester.enterText(find.byKey(const Key('editor-body')), longBody);
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    final saved = state.entryRepo.findById(state.selected!.id)!;
    expect(saved.bodyMd.length, longBody.length);

    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '长文预览不应抛异常');

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
    expect(entry.bodyMd, contains('![shot.png](assets/'));
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

  testWidgets('默认数据目录不可写时，首页常驻提示改用的目录', (tester) async {
    final noticeState = AppState(
      db: db,
      entryRepo: state.entryRepo,
      attachmentRepo: state.attachmentRepo,
      metaRepo: state.metaRepo,
      store: state.store,
      markdownIo: state.markdownIo,
      filePicker: () async => null,
      directoryPicker: (title) async => null,
      dataRootPath: '${tempDir.path}/MDiaryData',
      dataRootNotice: r'C:\Users\demo\AppData\Roaming\MDiary（拒绝访问，errno = 5）',
    );
    await noticeState.bootstrap();
    addTearDown(noticeState.dispose);

    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MDiaryApp(state: noticeState));
    await tester.pumpAndSettle();

    expect(find.textContaining('默认数据目录不可写'), findsOneWidget);
    expect(find.textContaining('MDiaryData'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '提示条不应把 800x600 的布局挤溢出');

    // 文字再长也不能把「打开目录」按钮顶出可视区域
    final button = tester.getRect(find.widgetWithText(TextButton, '打开目录'));
    expect(button.right, lessThanOrEqualTo(tester.view.physicalSize.width));
  }, skip: skipWidgetTests);

  testWidgets('设置页「更改数据目录」选到同一目录时只提示，不迁移', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MDiaryApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('更改数据目录'),
      200,
      scrollable: scrollable,
    );

    nextDirectory = tempDir.path; // 与当前数据目录相同
    await tester.tap(find.text('更改数据目录'));
    await tester.pumpAndSettle();

    expect(find.text('这已经是当前数据目录'), findsOneWidget);
    expect(state.dataRootPath, tempDir.path);

    // 放掉 SnackBar 的自动关闭计时器
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }, skip: skipWidgetTests);

  testWidgets('左侧日历：切到上个月点 15 号，新建那天的日记', (tester) async {
    await pumpApp(tester);
    final calendar = find.byType(MonthCalendar);
    expect(calendar, findsOneWidget);

    await tester.tap(
      find.descendant(of: calendar, matching: find.byTooltip('上个月')),
    );
    await tester.pumpAndSettle();
    final month = state.calendarMonth;

    await tester.tap(
      find.descendant(of: calendar, matching: find.text('15')).first,
    );
    await tester.pumpAndSettle();

    expect(state.selected, isNotNull);
    expect(state.selected!.entryDate, DateTime(month.year, month.month, 15));
    expect(state.entryRepo.count(), 1);
    expect(state.selectedDate, DateTime(month.year, month.month, 15));
  }, skip: skipWidgetTests);

  testWidgets('左侧日历：那天已有日记时再次点开不会重复新建', (tester) async {
    await pumpApp(tester);
    final calendar = find.byType(MonthCalendar);

    await tester.tap(
      find.descendant(of: calendar, matching: find.byTooltip('上个月')),
    );
    await tester.pumpAndSettle();
    final month = state.calendarMonth;

    await tester.tap(
      find.descendant(of: calendar, matching: find.text('8')).first,
    );
    await tester.pumpAndSettle();
    final firstId = state.selected!.id;

    // 写点内容：空草稿在切换日期时会被清理掉，那就测不出「重复新建」了
    await tester.enterText(find.byKey(const Key('editor-title')), '八号');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    // 切到今天，再切回上个月 8 号
    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editor-title')), '今天写的');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(MonthCalendar),
        matching: find.byTooltip('上个月'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(MonthCalendar),
        matching: find.text('8'),
      ).first,
    );
    await tester.pumpAndSettle();

    expect(state.selected!.id, firstId, reason: '应打开原来那篇，而不是新建');
    expect(state.selected!.title, '八号');
    expect(
      state.entryRepo.count(),
      2,
      reason: '8 号一篇 + 今天一篇，重复点 8 号不应再加',
    );
    expect(state.calendarMonth, DateTime(month.year, month.month));
  }, skip: skipWidgetTests);

  testWidgets('标签：编辑器里添加后列表与搜索都能看到', (tester) async {
    await pumpApp(tester);
    await createEntry(tester);

    await tester.tap(find.text('添加标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '旅行, 杭州');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final id = state.selected!.id;
    expect(state.tagsOf(id).toSet(), <String>{'旅行', '杭州'});
    expect(find.text('#旅行'), findsWidgets);
    expect(find.text('#杭州'), findsWidgets);
    expect(find.text('编辑标签'), findsOneWidget);

    // 搜索框输入标签名也能过滤出这一篇
    await tester.enterText(find.byType(TextField).first, '杭州');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(state.entries, hasLength(1));
  }, skip: skipWidgetTests);

  testWidgets('星图：展示日记与共用附件，点日记星回到编辑器', (tester) async {
    final first = state.entryRepo.create(
      deviceId: 'dev',
      date: DateTime(2026, 11, 1),
      title: '第一篇',
    );
    final second = state.entryRepo.create(
      deviceId: 'dev',
      date: DateTime(2026, 11, 2),
      title: '第二篇',
    );
    await state.refresh();
    // 两篇日记索引同一个附件（同 sha）——只写库，不碰磁盘，避免 widget 测试里等真实 IO
    for (final entry in <Entry>[first, second]) {
      state.attachmentRepo.insert(
        entryId: entry.id,
        sha256: 'deadbeef' * 8,
        filename: 'shot.png',
        mime: 'image/png',
        sizeBytes: 4,
      );
    }

    await pumpApp(tester);
    await tester.tap(find.byTooltip('星图'));
    await tester.pumpAndSettle();

    expect(find.text('星图'), findsOneWidget);
    for (final label in <String>['全部', '年', '月', '周']) {
      expect(find.text(label), findsWidgets, reason: '缺少「$label」分组');
    }
    expect(tester.takeException(), isNull);

    final map = buildStarMap(
      entries: state.allEntries,
      attachments: state.allAttachments,
      period: StarPeriod.month,
    );
    expect(map.attachments.single.refCount, 2);

    // 点第一颗日记星 -> 回到主界面并选中它
    final viewer = find.byType(InteractiveViewer);
    final origin = tester.getTopLeft(viewer);
    await tester.tapAt(origin + map.entries.first.center);
    await tester.pumpAndSettle();

    expect(find.text('星图'), findsNothing, reason: '应已返回主界面');
    expect(state.selected?.id, map.entries.first.entry.id);
  }, skip: skipWidgetTests);

  testWidgets('星图：切换全部/年/月/周不报错', (tester) async {
    await state.createEntry(date: DateTime(2026, 11, 1));
    await pumpApp(tester);
    await tester.tap(find.byTooltip('星图'));
    await tester.pumpAndSettle();

    for (final label in <String>['周', '年', '全部']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '切到「$label」时异常');
    }
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
