import '../data/entry_repository.dart';
import '../data/models.dart';
import '../data/tag_repository.dart';
import 'content_hash.dart';
import 'rag_database.dart';
import 'summarizer.dart';

/// 一次每日语义管理的结果。
class DailyRunReport {
  const DailyRunReport({
    required this.date,
    required this.summarized,
    required this.skipped,
    required this.failed,
    required this.errors,
    required this.model,
    required this.elapsedMs,
    this.skippedReason,
  });

  final String date;
  final int summarized;
  final int skipped;
  final int failed;
  final List<String> errors;
  final String model;
  final int elapsedMs;

  /// 没有实际执行时的原因（今天已经跑过 / 模型不可用）。
  final String? skippedReason;

  bool get ok => failed == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'date': date,
    'summarized': summarized,
    'skipped': skipped,
    'failed': failed,
    'model': model,
    'elapsedMs': elapsedMs,
    'skippedReason': skippedReason,
    if (errors.isNotEmpty) 'errors': errors,
  };

  @override
  String toString() {
    if (skippedReason != null) return '每日整理跳过：$skippedReason';
    return '每日整理完成（$date）：新增摘要 $summarized 篇、跳过 $skipped 篇'
        '${failed == 0 ? '' : '、失败 $failed 篇'}'
        '（$model，${(elapsedMs / 1000).toStringAsFixed(1)}s）';
  }
}

/// 每日语义管理（2.0.4）：对「新增 / 修改过」的日记生成摘要与标签建议。
///
/// 只写 `entry_summary`，**不改用户标签**；模型不可用时整次任务失败，
/// 不写 `last_daily_run`，下次启动会重试。
class DailySemanticJob {
  DailySemanticJob({
    required this.rag,
    required this.entries,
    required this.tags,
    required this.summarizer,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RagDatabase rag;
  final EntryRepository entries;
  final TagRepository tags;
  final Summarizer summarizer;
  final DateTime Function() _clock;

  static const String lastRunKey = 'last_daily_run';
  static const String jobKind = 'daily';

  /// 今天是否还没跑过。
  Future<bool> isDue() async => rag.meta(lastRunKey) != today(_clock());

  /// 启动时调用：今天没跑过才跑。
  Future<DailyRunReport> runIfDue({bool force = false}) async {
    if (!force && !await isDue()) {
      return DailyRunReport(
        date: today(_clock()),
        summarized: 0,
        skipped: 0,
        failed: 0,
        errors: const <String>[],
        model: summarizer.modelId,
        elapsedMs: 0,
        skippedReason: '今天已经整理过了',
      );
    }
    return run(force: force);
  }

  Future<DailyRunReport> run({bool force = false}) async {
    final started = _clock();
    final date = today(started);
    final jobId = '$jobKind:$date';
    rag.upsertJob(
      id: jobId,
      kind: jobKind,
      targetDate: date,
      status: 'running',
    );

    var summarized = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];

    try {
      for (final entry in entries.query()) {
        final entryTags = tags.tagsOf(entry.id);
        final hash = entryContentHash(entry, entryTags);
        if (!force && rag.entrySummaryHash(entry.id) == hash) {
          skipped++;
          continue;
        }
        try {
          final result = await summarizer.summarize(
            title: entry.title,
            date: entry.entryDate,
            body: entry.bodyMd,
            tags: entryTags,
          );
          rag.upsertEntrySummary(
            entryId: entry.id,
            summary: result.summary,
            tags: result.tags,
            sourceHash: hash,
            model: summarizer.modelId,
          );
          summarized++;
        } on SummarizerUnavailable {
          rethrow;
        } on Object catch (error) {
          failed++;
          errors.add('《${entry.title}》：$error');
        }
      }

      rag.setMeta(lastRunKey, date);
      rag.upsertJob(
        id: jobId,
        kind: jobKind,
        targetDate: date,
        status: failed == 0 ? 'done' : 'partial',
        lastError: errors.isEmpty ? null : errors.join('；'),
      );
    } on Object catch (error) {
      rag.upsertJob(
        id: jobId,
        kind: jobKind,
        targetDate: date,
        status: 'failed',
        attempts: 1,
        lastError: '$error',
      );
      rethrow;
    }

    return DailyRunReport(
      date: date,
      summarized: summarized,
      skipped: skipped,
      failed: failed,
      errors: errors,
      model: summarizer.modelId,
      elapsedMs: _clock().difference(started).inMilliseconds,
    );
  }

  /// 某篇的摘要（没有则 null）。
  String? summaryOf(String entryId) => rag.entrySummaryOf(entryId);

  /// 某篇的标签建议（只展示，不自动写入）。
  List<String> suggestedTagsOf(String entryId) => rag.suggestedTagsOf(entryId);

  static String today(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

/// 启动时在后台跑：先增量索引，再生成摘要；任何一步失败只记日志。
Future<DailyRunReport?> runDailyInBackground({
  required DailySemanticJob job,
  required Future<void> Function() reindex,
  required Summarizer summarizer,
  required void Function(String message) log,
}) async {
  try {
    if (!await job.isDue()) return null;
    if (!await summarizer.isAvailable()) {
      log('每日整理跳过：本地模型不可用（${summarizer.modelId}）');
      return null;
    }
    await reindex();
    final report = await job.run();
    log(report.toString());
    for (final error in report.errors.take(3)) {
      log('  摘要失败：$error');
    }
    return report;
  } on Object catch (error) {
    log('每日整理失败：$error');
    return null;
  }
}

/// 便于测试/展示：把一批条目按 id 排序。
List<Entry> sortedByDate(List<Entry> list) {
  final copy = <Entry>[...list];
  copy.sort((a, b) => a.entryDate.compareTo(b.entryDate));
  return copy;
}
