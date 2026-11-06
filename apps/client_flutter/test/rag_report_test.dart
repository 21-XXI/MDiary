@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/rag/rag_database.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/report_job.dart';
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
  late AttachmentRepository attachments;
  late RagDatabase rag;
  late DateTime now;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_report_');
    libraryRoot = Directory(p.join(sandbox.path, 'lib'))..createSync();
    Directory(p.join(libraryRoot.path, 'db')).createSync(recursive: true);
    db = AppDatabase.open(p.join(libraryRoot.path, 'db', 'mdiary.sqlite'));
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    rag = RagDatabase.open(RagService.indexPathFor(libraryRoot.path));
    now = DateTime(2026, 11, 6, 9, 0);
  });

  tearDown(() {
    rag.close();
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  DailyReportJob jobWith(Summarizer summarizer) => DailyReportJob(
    rag: rag,
    entries: entries,
    attachments: attachments,
    summarizer: summarizer,
    clock: () => now,
  );

  File reportFile(DateTime date) => File(
    p.join(
      libraryRoot.path,
      'rag',
      'reports',
      '${DailyReportJob.dateKey(date)}.md',
    ),
  );

  test('空日也生成日报：写「没有写日记」而不是跳过', () async {
    final job = jobWith(FakeSummarizer());
    final result = await job.generate(DateTime(2026, 11, 5));

    expect(result.skipped, isFalse);
    expect(result.markdown, contains('这一天没有写日记'));
    expect(reportFile(DateTime(2026, 11, 5)).existsSync(), isTrue);
    expect(rag.reportOf('2026-11-05'), contains('没有写日记'));
  }, skip: skip);

  test('有内容的日子：三段式 + 引用 + 附件名', () async {
    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 3),
      title: '报销',
      body: '把发票整理好了，住宿费 380 元。',
    );
    attachments.insert(
      entryId: entry.id,
      sha256: 'a' * 64,
      filename: '发票.txt',
      mime: 'text/plain',
      sizeBytes: 20,
    );

    final job = jobWith(FakeSummarizer());
    final result = await job.generate(DateTime(2026, 11, 3));

    expect(result.skipped, isFalse);
    expect(result.model, 'fake:fake');
    expect(result.markdown, contains('## 今天写了什么'));
    expect(result.markdown, contains('## 关键点 / 待办'));
    expect(result.markdown, contains('## 一句话总结'));
    expect(result.markdown, contains('2026-11-03-报销'));
    expect(result.markdown, contains('发票.txt'));
  }, skip: skip);

  test('已有日报默认跳过，force 才覆盖', () async {
    final job = jobWith(FakeSummarizer());
    await job.generate(DateTime(2026, 11, 4));

    final again = await job.generate(DateTime(2026, 11, 4));
    expect(again.skipped, isTrue);

    final forced = await job.generate(DateTime(2026, 11, 4), force: true);
    expect(forced.skipped, isFalse);
  }, skip: skip);

  test('backfill 补齐 [最早日记, 昨天]，今天不生成', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '第一天',
      body: '开始记。',
    );
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 3),
      title: '第三天',
      body: '继续。',
    );

    final job = jobWith(FakeSummarizer());
    final run = await job.backfill();

    expect(run.generated, 5, reason: '11-01 到 11-05 共 5 天');
    expect(run.failed, 0);
    for (var day = 1; day <= 5; day++) {
      expect(
        reportFile(DateTime(2026, 11, day)).existsSync(),
        isTrue,
        reason: '11-0$day 应该有日报',
      );
    }
    expect(reportFile(DateTime(2026, 11, 6)).existsSync(), isFalse);
    expect(
      reportFile(DateTime(2026, 11, 2)).readAsStringSync(),
      contains('这一天没有写日记'),
      reason: '空日也要有日报',
    );
    expect(await job.isDue(), isFalse);
  }, skip: skip);

  test('模型不可用时退化为离线骨架，仍然写文件', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 5),
      title: '有内容',
      body: '正文。',
    );
    final job = jobWith(_BrokenReportSummarizer());
    final result = await job.generate(DateTime(2026, 11, 5));

    expect(result.skipped, isFalse);
    expect(result.model, isEmpty, reason: '没有模型参与');
    expect(result.markdown, contains('离线骨架'));
    expect(reportFile(DateTime(2026, 11, 5)).existsSync(), isTrue);
  }, skip: skip);

  test('连续空日会在日报里提示', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '起点',
      body: '正文。',
    );
    final job = jobWith(FakeSummarizer());
    final result = await job.generate(DateTime(2026, 11, 4));

    expect(result.markdown, contains('这一天没有写日记'));
    expect(result.markdown, contains('已经连续 3 天没有记录'));
  }, skip: skip);
}

/// 报告生成失败，但「可用性检查」通过：走离线骨架分支。
class _BrokenReportSummarizer extends FakeSummarizer {
  @override
  Future<String> generateReport({
    required DateTime date,
    required List<ReportInput> items,
    required List<String> attachments,
  }) async {
    throw SummarizerUnavailable('模拟模型挂了');
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
