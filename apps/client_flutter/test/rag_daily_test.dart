@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/daily_job.dart';
import 'package:mdiary/rag/rag_database.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/summarizer.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory sandbox;
  late Directory libraryRoot;
  late AppDatabase db;
  late EntryRepository entries;
  late TagRepository tags;
  late RagDatabase rag;
  late DateTime now;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_daily_');
    libraryRoot = Directory(p.join(sandbox.path, 'lib'))..createSync();
    Directory(p.join(libraryRoot.path, 'db')).createSync(recursive: true);
    db = AppDatabase.open(p.join(libraryRoot.path, 'db', 'mdiary.sqlite'));
    entries = EntryRepository(db);
    tags = TagRepository(db);
    rag = RagDatabase.open(RagService.indexPathFor(libraryRoot.path));
    now = DateTime(2026, 11, 6, 9, 30);
  });

  tearDown(() {
    rag.close();
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  DailySemanticJob jobWith(Summarizer summarizer) => DailySemanticJob(
    rag: rag,
    entries: entries,
    tags: tags,
    summarizer: summarizer,
    clock: () => now,
  );

  test('第一次跑：给所有日记写摘要，并记录 job 与 last_daily_run', () async {
    final a = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '杭州',
      body: '去了西湖，风很大。',
    );
    final b = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 2),
      title: '工作',
      body: '和产品对排期。',
    );
    tags.setTags(b.id, <String>['工作']);

    final job = jobWith(FakeSummarizer());
    final report = await job.run();

    expect(report.summarized, 2);
    expect(report.failed, 0);
    expect(rag.entrySummaryOf(a.id), isNotNull);
    expect(rag.entrySummaryOf(a.id), contains('杭州'));
    expect(rag.suggestedTagsOf(b.id), contains('自动整理'));

    final jobRow = rag.job('daily:2026-11-06');
    expect(jobRow, isNotNull);
    expect(jobRow!['status'], 'done');
    expect(await job.isDue(), isFalse);
  }, skip: skip);

  test('同一天再跑会跳过；手动 force 才会重跑', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final job = jobWith(FakeSummarizer());
    await job.run();

    final again = await job.runIfDue();
    expect(again.summarized, 0);
    expect(again.skippedReason, isNotNull);

    final forced = await job.runIfDue(force: true);
    expect(forced.summarized, 1);
  }, skip: skip);

  test('只给改动过的日记重新写摘要', () async {
    final a = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '原文。',
    );
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 2),
      title: '乙',
      body: '另一篇。',
    );
    final job = jobWith(FakeSummarizer());
    await job.run();

    entries.saveContent(a.id, body: '原文，又补了一段。');
    final report = await job.run();

    expect(report.summarized, 1);
    expect(report.skipped, 1);
  }, skip: skip);

  test('标签建议不会自动改用户标签', () async {
    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final job = jobWith(FakeSummarizer());
    await job.run();

    expect(tags.tagsOf(entry.id), isEmpty);
    expect(rag.suggestedTagsOf(entry.id), isNotEmpty);
  }, skip: skip);

  test('模型不可用时整次失败：job=failed，且不写 last_daily_run', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final job = jobWith(_FailingSummarizer());

    await expectLater(job.run(), throwsA(isA<SummarizerUnavailable>()));
    final jobRow = rag.job('daily:2026-11-06');
    expect(jobRow!['status'], 'failed');
    expect('${jobRow['last_error']}', contains('模型挂了'));
    expect(await job.isDue(), isTrue, reason: '失败后下次启动应重试');
  }, skip: skip);

  test('改期后（新的一天）会再次执行', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final job = jobWith(FakeSummarizer());
    await job.run();
    expect(await job.isDue(), isFalse);

    now = DateTime(2026, 11, 7, 8, 0);
    expect(await job.isDue(), isTrue);
    final report = await job.runIfDue();
    expect(report.summarized, 0, reason: '内容没变就不重复写摘要');
    expect(report.skipped, 1);
    expect(await job.isDue(), isFalse);
    expect(rag.job('daily:2026-11-07')!['status'], 'done');
  }, skip: skip);
}

class _FailingSummarizer implements Summarizer {
  @override
  String get modelId => 'failing';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<EntrySummary> summarize({
    required String title,
    required DateTime date,
    required String body,
    required List<String> tags,
  }) async {
    throw SummarizerUnavailable('模型挂了');
  }
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
