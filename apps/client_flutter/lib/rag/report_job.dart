import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/attachment_repository.dart';
import '../data/entry_repository.dart';
import '../data/models.dart';
import 'rag_database.dart';
import 'summarizer.dart';

/// 一次日报生成的结果。
class DailyReportRun {
  const DailyReportRun({
    required this.generated,
    required this.skipped,
    required this.failed,
    required this.errors,
    required this.model,
    required this.elapsedMs,
    this.skippedReason,
  });

  final int generated;
  final int skipped;
  final int failed;
  final List<String> errors;
  final String model;
  final int elapsedMs;
  final String? skippedReason;

  bool get ok => failed == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'generated': generated,
    'skipped': skipped,
    'failed': failed,
    'model': model,
    'elapsedMs': elapsedMs,
    'skippedReason': skippedReason,
    if (errors.isNotEmpty) 'errors': errors,
  };

  @override
  String toString() {
    if (skippedReason != null) return '日报跳过：$skippedReason';
    return '日报完成：生成 $generated 天、跳过 $skipped 天'
        '${failed == 0 ? '' : '、失败 $failed 天'}'
        '（$model，${(elapsedMs / 1000).toStringAsFixed(1)}s）';
  }
}

/// 单天生成的结果。
class DailyReportResult {
  const DailyReportResult({
    required this.date,
    required this.markdown,
    required this.model,
    required this.skipped,
    this.error,
  });

  final DateTime date;
  final String markdown;
  final String model;
  final bool skipped;
  final String? error;
}

/// 日报（2.0.5）：`rag/reports/YYYY-MM-DD.md` + `report` 表。
///
/// - 每天一篇，**空日也写**：「这一天没有写日记」+ 连续空日提示；
/// - 有内容时先拼「离线骨架」，模型可用再润色成三段式日报；
/// - 启动时补齐缺失日期（默认回看 366 天，可调）。
class DailyReportJob {
  DailyReportJob({
    required this.rag,
    required this.entries,
    required this.attachments,
    required this.summarizer,
    this.maxBackfillDays = 366,
    this.modelPolishDays = 30,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RagDatabase rag;
  final EntryRepository entries;
  final AttachmentRepository attachments;
  final Summarizer summarizer;
  final int maxBackfillDays;
  final int modelPolishDays;
  final DateTime Function() _clock;

  static const String lastRunKey = 'last_report_run';

  String get reportsDirectory => p.join(p.dirname(rag.path), 'reports');

  Future<bool> isDue() async => rag.meta(lastRunKey) != dateKey(_clock());

  Future<DailyReportRun> runIfDue({bool force = false}) async {
    if (!force && !await isDue()) {
      return DailyReportRun(
        generated: 0,
        skipped: 0,
        failed: 0,
        errors: const <String>[],
        model: summarizer.modelId,
        elapsedMs: 0,
        skippedReason: '今天的日报已经补过了',
      );
    }
    return backfill(force: force);
  }

  /// 补齐 [最早日记, 昨天] 之间缺失的日报（最多 [maxBackfillDays] 天）。
  Future<DailyReportRun> backfill({bool force = false}) async {
    final started = _clock();
    final today = DateTime(started.year, started.month, started.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final byDay = _entriesByDay();

    DateTime start;
    if (byDay.isEmpty) {
      start = yesterday.subtract(const Duration(days: 6));
    } else {
      final earliest = byDay.keys.map(_parseDate).reduce(
        (a, b) => a.isBefore(b) ? a : b,
      );
      start = earliest;
    }
    final span = yesterday.difference(start).inDays + 1;
    if (span > maxBackfillDays) {
      start = yesterday.subtract(Duration(days: maxBackfillDays - 1));
    }
    if (start.isAfter(yesterday)) start = yesterday;

    var generated = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    final cutoff = today.subtract(Duration(days: modelPolishDays));

    for (
      var day = start;
      !day.isAfter(yesterday);
      day = day.add(const Duration(days: 1))
    ) {
      try {
        final result = await generate(
          day,
          force: force,
          allowModel: !day.isBefore(cutoff),
        );
        if (result.skipped) {
          skipped++;
        } else {
          generated++;
        }
      } on Object catch (error) {
        failed++;
        errors.add('${dateKey(day)}：$error');
      }
    }

    rag.setMeta(lastRunKey, dateKey(today));
    rag.upsertJob(
      id: 'report:${dateKey(today)}',
      kind: 'report',
      targetDate: dateKey(today),
      status: failed == 0 ? 'done' : 'partial',
      lastError: errors.isEmpty ? null : errors.join('；'),
    );

    return DailyReportRun(
      generated: generated,
      skipped: skipped,
      failed: failed,
      errors: errors,
      model: summarizer.modelId,
      elapsedMs: _clock().difference(started).inMilliseconds,
    );
  }

  /// 生成某一天的日报；已存在且 [force] 为 false 时返回 skipped。
  Future<DailyReportResult> generate(
    DateTime date, {
    bool force = false,
    bool allowModel = true,
  }) async {
    final key = dateKey(date);
    final existing = rag.reportOf(key);
    if (existing != null && !force) {
      return DailyReportResult(
        date: date,
        markdown: existing,
        model: rag.reportModelOf(key) ?? '',
        skipped: true,
      );
    }

    final dayEntries = (_entriesByDay()[key] ?? const <Entry>[])
        .toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final fileNames = <String>[];
    final titlesById = <String, String>{};
    for (final entry in dayEntries) {
      titlesById[entry.id] = entry.title;
      for (final attachment in attachments.listByEntry(entry.id)) {
        if (!fileNames.contains(attachment.filename)) {
          fileNames.add(attachment.filename);
        }
      }
    }

    var model = '';
    String markdown;
    String? error;

    if (dayEntries.isEmpty) {
      markdown = _emptyDayMarkdown(date, _consecutiveEmptyDays(date));
      model = 'system';
    } else {
      final items = <ReportInput>[
        for (final entry in dayEntries)
          ReportInput(
            title: entry.title,
            date: entry.entryDate,
            summary: rag.entrySummaryOf(entry.id) ?? _firstLine(entry.bodyMd),
            body: entry.bodyMd,
          ),
      ];
      final skeleton = _skeletonMarkdown(
        date: date,
        entries: dayEntries,
        attachments: fileNames,
      );
      markdown = skeleton;
      if (allowModel) {
        try {
          final available = await summarizer.isAvailable();
          if (available) {
            final body = await summarizer.generateReport(
              date: date,
              items: items,
              attachments: fileNames,
            );
            markdown = _withHeader(date, body);
            model = summarizer.modelId;
          } else {
            markdown = _skeletonMarkdown(
              date: date,
              entries: dayEntries,
              attachments: fileNames,
              note: '本机模型不可用，以下为离线骨架，可直接阅读。',
            );
            error = '模型不可用，已写离线骨架';
          }
        } on SummarizerUnavailable catch (failure) {
          markdown = _skeletonMarkdown(
            date: date,
            entries: dayEntries,
            attachments: fileNames,
            note: '模型调用失败（$failure），以下为离线骨架。',
          );
          error = '$failure';
        }
      } else {
        markdown = _skeletonMarkdown(
          date: date,
          entries: dayEntries,
          attachments: fileNames,
        );
      }
    }

    _writeReportFile(key, markdown);
    rag.upsertReport(date: key, markdown: markdown, model: model);

    return DailyReportResult(
      date: date,
      markdown: markdown,
      model: model,
      skipped: false,
      error: error,
    );
  }

  String? markdownOf(DateTime date) => rag.reportOf(dateKey(date));

  List<DateTime> reportDates() =>
      rag.reportDates().map(_parseDate).toList(growable: false);

  String _withHeader(DateTime date, String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('# ')) return trimmed;
    return '# ${dateKey(date)} 日报\n\n$trimmed\n';
  }

  String _emptyDayMarkdown(DateTime date, int consecutive) {
    final buffer = StringBuffer()
      ..writeln('# ${dateKey(date)} 日报')
      ..writeln()
      ..writeln('这一天没有写日记，也没有新增附件。');
    if (consecutive > 1) {
      buffer
        ..writeln()
        ..writeln('> 已经连续 $consecutive 天没有记录。');
    }
    return buffer.toString();
  }

  String _skeletonMarkdown({
    required DateTime date,
    required List<Entry> entries,
    required List<String> attachments,
    String? note,
  }) {
    final buffer = StringBuffer()
      ..writeln('# ${dateKey(date)} 日报')
      ..writeln();
    if (note != null) {
      buffer
        ..writeln('> $note')
        ..writeln();
    }
    buffer
      ..writeln('## 今天写了什么')
      ..writeln();
    for (final entry in entries) {
      final summary = (rag.entrySummaryOf(entry.id) ?? '').trim();
      final fallback = _firstLine(entry.bodyMd);
      final text = summary.isNotEmpty ? summary : fallback;
      buffer.writeln(
        '- [${dateKey(entry.entryDate)}-${_displayTitle(entry)}] '
        '${text.isEmpty ? '（空白）' : text}',
      );
    }
    if (attachments.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 附件')
        ..writeln();
      for (final name in attachments) {
        buffer.writeln('- $name');
      }
    }
    buffer
      ..writeln()
      ..writeln('## 关键点 / 待办')
      ..writeln()
      ..writeln('- （离线骨架未提炼，等模型可用后重新生成即可）')
      ..writeln()
      ..writeln('## 一句话总结')
      ..writeln()
      ..writeln('这一天记了 ${entries.length} 篇，附件 ${attachments.length} 个。');
    return buffer.toString();
  }

  void _writeReportFile(String key, String markdown) {
    final dir = Directory(reportsDirectory)..createSync(recursive: true);
    final target = File(p.join(dir.path, '$key.md'));
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(markdown, flush: true);
    temp.renameSync(target.path);
  }

  Map<String, List<Entry>> _entriesByDay() {
    final result = <String, List<Entry>>{};
    for (final entry in entries.query()) {
      result.putIfAbsent(dateKey(entry.entryDate), () => <Entry>[]).add(entry);
    }
    return result;
  }

  int _consecutiveEmptyDays(DateTime date) {
    final byDay = _entriesByDay();
    var count = 0;
    var cursor = DateTime(date.year, date.month, date.day);
    for (var i = 0; i < 3650; i++) {
      if (byDay.containsKey(dateKey(cursor))) break;
      count++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return count;
  }

  static String _firstLine(String body) {
    for (final line in body.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      if (text.startsWith('#')) continue;
      return text.length <= 80 ? text : '${text.substring(0, 80)}…';
    }
    return '';
  }

  static String _displayTitle(Entry entry) {
    final title = entry.title.trim();
    if (title.isNotEmpty) return title;
    final first = _firstLine(entry.bodyMd);
    return first.isEmpty ? '无标题' : first;
  }

  static String dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static DateTime _parseDate(String key) {
    final parts = key.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}
