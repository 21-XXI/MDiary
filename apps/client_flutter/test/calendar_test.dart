@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/material.dart' show DateUtils;
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:sqlite3/open.dart';

/// 左栏日历的状态逻辑：默认日期、点选新建/打开、标记、月份切换。
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
    tempDir = Directory.systemTemp.createTempSync('mdiary_calendar_');
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

  test('空库：日历停在今天，没有标记', () async {
    expect(DateUtils.isSameDay(state.selectedDate, DateTime.now()), isTrue);
    expect(state.calendarMonth, DateTime(DateTime.now().year, DateTime.now().month));
    expect(state.markedDates, isEmpty);
  }, skip: skip);

  test('点日历的某天：没有日记就新建，日期就是那天', () async {
    final day = DateTime(2026, 10, 3);
    final entry = await state.selectDay(day);

    expect(entry.entryDate, DateTime(2026, 10, 3));
    expect(state.selected?.id, entry.id);
    expect(state.selectedDate, DateTime(2026, 10, 3));
    expect(state.calendarMonth, DateTime(2026, 10));
    expect(state.markedDates, contains(DateTime(2026, 10, 3)));
    expect(state.entries, hasLength(1));
    expect(state.entryRepo.count(), 1);
  }, skip: skip);

  test('那天已有日记：打开原来那篇，不重复新建', () async {
    final first = await state.selectDay(DateTime(2026, 9, 9));
    state.draftChanged(title: '九月九日', body: '内容', immediate: true);
    await state.flushNow();

    final again = await state.selectDay(DateTime(2026, 9, 9));

    expect(again.id, first.id);
    expect(state.entryRepo.count(), 1);
    expect(state.selected?.title, '九月九日');
  }, skip: skip);

  test('同一天有多篇时打开最近更新的一篇', () async {
    await state.selectDay(DateTime(2026, 8, 1));
    state.draftChanged(title: '先写的', immediate: true);
    await state.flushNow();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final latest = await state.createEntry(date: DateTime(2026, 8, 1));
    state.draftChanged(title: '后写的', immediate: true);
    await state.flushNow();

    final opened = await state.selectDay(DateTime(2026, 8, 1));

    expect(opened.id, latest.id);
    expect(state.entryRepo.count(), 2);
  }, skip: skip);

  test('历史日期的日记按日期排，不会跑到列表最前面', () async {
    await state.createEntry(date: DateTime(2026, 11, 2));
    state.draftChanged(title: '十一月', immediate: true);
    await state.flushNow();
    await state.selectDay(DateTime(2026, 3, 1));

    expect(state.entries, hasLength(2));
    expect(state.entries.first.entryDate, DateTime(2026, 11, 2));
    expect(
      state.entries.last.entryDate,
      DateTime(2026, 3, 1),
      reason: '列表应按日期倒序，历史日期不能插到最前面',
    );
  }, skip: skip);

  test('列表里点开某篇，日历跟着跳到那天', () async {
    final old = await state.selectDay(DateTime(2026, 7, 15));
    await state.createEntry(date: DateTime(2026, 11, 1));
    state.draftChanged(title: '十一月', immediate: true);
    await state.flushNow();

    await state.select(old);

    expect(state.selectedDate, DateTime(2026, 7, 15));
    expect(state.calendarMonth, DateTime(2026, 7));
  }, skip: skip);

  test('showMonth 只切显示，不建日记', () async {
    final before = state.entryRepo.count();
    state.showMonth(DateTime(2025, 1, 20));
    expect(state.calendarMonth, DateTime(2025, 1));
    expect(state.entryRepo.count(), before);
  }, skip: skip);

  test('删掉某天的日记后，小圆点消失', () async {
    final entry = await state.selectDay(DateTime(2026, 6, 6));
    expect(state.markedDates, contains(DateTime(2026, 6, 6)));

    state.entryRepo.softDelete(entry.id);
    await state.refresh();

    expect(state.markedDates, isNot(contains(DateTime(2026, 6, 6))));
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
