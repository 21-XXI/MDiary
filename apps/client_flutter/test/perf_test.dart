@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:sqlite3/open.dart';

/// 验收 D5：1,000 篇日记下列表首屏 < 300ms、搜索 < 500ms。
/// 这里测的是数据层耗时（UI 渲染另有 widget 测试覆盖，真实首屏还要加上一帧布局）。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory tempDir;
  late AppDatabase db;
  late EntryRepository entries;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mdiary_perf_');
    db = AppDatabase.inMemory();
    entries = EntryRepository(db);
  });

  tearDown(() {
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('1000 篇：列表查询与中文搜索耗时', () {
    // 造数据：每篇约 600 字，贴近真实日记体量
    final insertWatch = Stopwatch()..start();
    db.raw.execute('BEGIN');
    for (var i = 0; i < 1000; i++) {
      final day = DateTime(2024, 1, 1).add(Duration(days: i));
      final body = StringBuffer()
        ..writeln('# 第 $i 篇')
        ..writeln()
        ..writeln('今天记录了一些琐事与想法，编号 $i。');
      for (var line = 0; line < 12; line++) {
        body.writeln('第 $line 段：一些用于模拟真实长度的正文内容，包含中文与 English 混合。');
      }
      entries.create(
        deviceId: 'perf',
        date: day,
        title: '第 $i 篇',
        body: body.toString(),
      );
    }
    db.raw.execute('COMMIT');
    insertWatch.stop();

    final listWatch = Stopwatch()..start();
    final list = entries.query();
    listWatch.stop();

    final searchWatch = Stopwatch()..start();
    final hits = entries.query(keyword: '第 500 篇');
    searchWatch.stop();

    final hotSearchWatch = Stopwatch()..start();
    final hotHits = entries.query(keyword: '琐事与想法');
    hotSearchWatch.stop();

    debugPrint(
      'PERF insert1000=${insertWatch.elapsedMilliseconds}ms '
      'list=${listWatch.elapsedMilliseconds}ms '
      'searchTitle=${searchWatch.elapsedMilliseconds}ms(hits=${hits.length}) '
      'searchBody=${hotSearchWatch.elapsedMilliseconds}ms(hits=${hotHits.length})',
    );

    expect(list.length, 1000);
    expect(hits, isNotEmpty);
    expect(hotHits.length, 1000, reason: '每篇正文都含该关键词');
    expect(
      listWatch.elapsedMilliseconds,
      lessThan(300),
      reason: '列表首屏 < 300ms（D5）',
    );
    expect(
      searchWatch.elapsedMilliseconds,
      lessThan(500),
      reason: '搜索 < 500ms（D5）',
    );
    expect(
      hotSearchWatch.elapsedMilliseconds,
      lessThan(500),
      reason: '正文全表搜索 < 500ms（D5）',
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
