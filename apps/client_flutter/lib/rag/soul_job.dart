import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/attachment_repository.dart';
import '../data/entry_repository.dart';
import '../data/models.dart';
import '../data/tag_repository.dart';
import 'rag_database.dart';
import 'summarizer.dart';

class SoulReport {
  const SoulReport({
    required this.generated,
    required this.path,
    required this.bytes,
    required this.model,
    required this.entries,
    required this.elapsedMs,
    this.skippedReason,
  });

  final bool generated;
  final String path;
  final int bytes;
  final String model;
  final int entries;
  final int elapsedMs;
  final String? skippedReason;

  Map<String, Object?> toJson() => <String, Object?>{
    'generated': generated,
    'path': path,
    'bytes': bytes,
    'model': model,
    'entries': entries,
    'elapsedMs': elapsedMs,
    'skippedReason': skippedReason,
  };

  @override
  String toString() {
    if (skippedReason != null) return '灵魂档案跳过：$skippedReason';
    return '灵魂档案已生成：$path（$bytes 字节，$entries 篇，$model，'
        '${(elapsedMs / 1000).toStringAsFixed(1)}s）';
  }
}

/// `rag/soul.md`：给大模型的「这个人 / 这个库」固定上下文（2.0.6）。
///
/// 预算 ≤ 8 KB；小节 1–4、6 由模型概括，5（时间线）与 7（检索说明）由程序生成。
/// 模型不可用时仍会写出统计版，不会让文件缺失。
class SoulJob {
  SoulJob({
    required this.rag,
    required this.entries,
    required this.tags,
    required this.attachments,
    required this.summarizer,
    this.minDays = 7,
    this.minNewEntries = 20,
    this.maxBytes = 8192,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RagDatabase rag;
  final EntryRepository entries;
  final TagRepository tags;
  final AttachmentRepository attachments;
  final Summarizer summarizer;
  final int minDays;
  final int minNewEntries;
  final int maxBytes;
  final DateTime Function() _clock;

  String get filePath => p.join(p.dirname(rag.path), 'soul.md');

  String? read() {
    final file = File(filePath);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  Future<bool> isDue() async {
    if (!File(filePath).existsSync()) return true;
    final generated = DateTime.tryParse(rag.meta('soul_generated_at') ?? '');
    if (generated == null) return true;
    if (_clock().difference(generated).inDays >= minDays) return true;
    final baseline = int.tryParse(rag.meta('soul_entry_count') ?? '') ?? 0;
    return entries.query().length - baseline >= minNewEntries;
  }

  Future<SoulReport> runIfDue({bool force = false}) async {
    if (!force && !await isDue()) {
      return SoulReport(
        generated: false,
        path: filePath,
        bytes: File(filePath).existsSync() ? File(filePath).lengthSync() : 0,
        model: rag.meta('soul_model') ?? '',
        entries: entries.query().length,
        elapsedMs: 0,
        skippedReason: '还没到重新生成的时候',
      );
    }
    return generate(force: force);
  }

  Future<SoulReport> generate({bool force = false}) async {
    final started = _clock();
    final all = entries.query();
    final tagsByEntry = tags.allTagsByEntry();
    final digest = _buildDigest(all, tagsByEntry);

    var model = '';
    String note = '';
    SoulSections? sections;
    if (all.isNotEmpty) {
      try {
        final available = await summarizer.isAvailable();
        if (available) {
          sections = await summarizer.generateSoul(digest: digest);
          model = summarizer.modelId;
        } else {
          note = '本机模型不可用，下面是统计版档案。';
        }
      } on Object catch (error) {
        note = '模型调用失败（$error），下面是统计版档案。';
      }
    }

    final markdown = _compose(
      all: all,
      tagsByEntry: tagsByEntry,
      sections: sections,
      note: note,
    );
    final capped = _capSize(markdown, maxBytes);

    final target = File(filePath);
    target.parent.createSync(recursive: true);
    if (target.existsSync()) {
      target.copySync('${target.path}.bak');
    }
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(capped, flush: true);
    temp.renameSync(target.path);

    rag.setMeta('soul_generated_at', started.toIso8601String());
    rag.setMeta('soul_entry_count', '${all.length}');
    rag.setMeta('soul_model', model);
    rag.upsertJob(
      id: 'soul:${_dateKey(started)}',
      kind: 'soul',
      targetDate: _dateKey(started),
      status: 'done',
    );

    return SoulReport(
      generated: true,
      path: target.path,
      bytes: utf8.encode(capped).length,
      model: model.isEmpty ? 'system' : model,
      entries: all.length,
      elapsedMs: _clock().difference(started).inMilliseconds,
    );
  }

  String _compose({
    required List<Entry> all,
    required Map<String, List<String>> tagsByEntry,
    required SoulSections? sections,
    required String note,
  }) {
    final libraryName = p.basename(p.dirname(p.dirname(rag.path)));
    final buffer = StringBuffer()
      ..writeln('# Soul — $libraryName')
      ..writeln()
      ..writeln(
        '> 覆盖 ${_rangeOf(all)} · ${all.length} 篇 · '
        '${attachments.all().length} 个附件 · '
        '模型 ${sections == null ? '未使用（统计版）' : summarizer.modelId} · '
        '生成于 ${_stamp(_clock())}',
      )
      ..writeln();
    if (note.isNotEmpty) {
      buffer
        ..writeln('> $note')
        ..writeln();
    }

    buffer
      ..writeln('## 1. 这个人')
      ..writeln()
      ..writeln(
        all.isEmpty ? '（还没有日记，暂时看不出来。）' : (sections?.person ?? '（需要模型才能归纳。）'),
      )
      ..writeln()
      ..writeln('## 2. 长期主题')
      ..writeln()
      ..writeln(all.isEmpty ? '（还没有日记。）' : (sections?.themes ?? '（需要模型才能归纳。）'))
      ..writeln()
      ..writeln('## 3. 重要的人 · 地点 · 项目')
      ..writeln()
      ..writeln(
        all.isEmpty
            ? '（还没有日记。）'
            : (sections?.peoplePlaces ?? '（需要模型才能归纳。）'),
      )
      ..writeln()
      ..writeln('## 4. 写作与语气')
      ..writeln()
      ..writeln(all.isEmpty ? '（还没有日记。）' : (sections?.style ?? '（需要模型才能归纳。）'))
      ..writeln()
      ..writeln('## 5. 时间线（每年一行）')
      ..writeln();
    final timeline = _timeline(all, tagsByEntry);
    if (timeline.isEmpty) {
      buffer.writeln('- （还没有日记）');
    } else {
      for (final line in timeline) {
        buffer.writeln('- $line');
      }
    }
    buffer
      ..writeln()
      ..writeln('## 6. 近期状态（最近 30 天）')
      ..writeln()
      ..writeln(
        sections?.recent ?? _fallbackRecent(all, tagsByEntry),
      )
      ..writeln()
      ..writeln('## 7. 如何检索这个库')
      ..writeln()
      ..writeln('- 标签词表：${_tagVocabulary(tagsByEntry)}')
      ..writeln('- 附件：正文里是 `assets/<原名>-<sha8>.<ext>`；用 `get_attachment` 取文件。')
      ..writeln('- 日报：`rag/reports/YYYY-MM-DD.md`（没有记录的日期也有，会写明「没有写日记」）。')
      ..writeln('- 工具：`search_diary` / `get_entry` / `get_attachment` / `get_soul` / `get_daily_report`。')
      ..writeln('- 索引：`rag/index.sqlite`（切片 + 向量），由 `tool/rag_search.dart` 重建。');
    return buffer.toString();
  }

  String _buildDigest(
    List<Entry> all,
    Map<String, List<String>> tagsByEntry,
  ) {
    final counts = <int, int>{};
    for (final entry in all) {
      counts[entry.entryDate.year] = (counts[entry.entryDate.year] ?? 0) + 1;
    }
    final topTags = _topTags(tagsByEntry, 20);
    final recent = _recentEntries(all, tagsByEntry, 20);
    final sample = _recentEntries(all, tagsByEntry, 60);

    final buffer = StringBuffer()
      ..writeln('总篇数：${all.length}')
      ..writeln('时间范围：${_rangeOf(all)}')
      ..writeln('每年篇数：${counts.entries.map((e) => '${e.key} 年 ${e.value} 篇').join('；')}')
      ..writeln('常见标签：${topTags.isEmpty ? '（无）' : topTags.join('、')}')
      ..writeln('附件：${attachments.all().length} 个')
      ..writeln()
      ..writeln('最近 30 天的记录：');
    for (final line in recent) {
      buffer.writeln('- $line');
    }
    buffer
      ..writeln()
      ..writeln('按时间最近的 60 条摘要样本：');
    for (final line in sample) {
      buffer.writeln('- $line');
    }
    return buffer.toString();
  }

  List<String> _timeline(
    List<Entry> all,
    Map<String, List<String>> tagsByEntry,
  ) {
    final byYear = <int, List<Entry>>{};
    for (final entry in all) {
      byYear.putIfAbsent(entry.entryDate.year, () => <Entry>[]).add(entry);
    }
    final years = byYear.keys.toList()..sort();
    return <String>[
      for (final year in years)
        '$year：${byYear[year]!.length} 篇 · 常见标签：'
            '${_topTagsFor(byYear[year]!, tagsByEntry, 3).join('、')}',
    ];
  }

  String _fallbackRecent(List<Entry> all, Map<String, List<String>> tagsByEntry) {
    final recent = _recentEntries(all, tagsByEntry, 5);
    if (recent.isEmpty) return '（最近 30 天没有记录。）';
    return recent.map((line) => '- $line').join('\n');
  }

  List<String> _recentEntries(
    List<Entry> all,
    Map<String, List<String>> tagsByEntry,
    int limit,
  ) {
    final cutoff = _clock().subtract(const Duration(days: 30));
    final sorted = <Entry>[...all]
      ..sort((a, b) => b.entryDate.compareTo(a.entryDate));
    final result = <String>[];
    for (final entry in sorted) {
      if (result.length >= limit) break;
      if (entry.entryDate.isBefore(cutoff)) continue;
      result.add(_describe(entry));
    }
    if (result.length >= limit) return result;
    for (final entry in sorted) {
      if (result.length >= limit) break;
      if (entry.entryDate.isBefore(cutoff)) {
        result.add(_describe(entry));
      }
    }
    return result;
  }

  String _describe(Entry entry) {
    final title = entry.title.trim().isEmpty ? '无标题' : entry.title.trim();
    final summary = (rag.entrySummaryOf(entry.id) ?? '').trim();
    final text = summary.isNotEmpty ? summary : _firstLine(entry.bodyMd);
    final clipped = text.length <= 80 ? text : '${text.substring(0, 80)}…';
    return '${_dateKey(entry.entryDate)}《$title》${clipped.isEmpty ? '' : '：$clipped'}';
  }

  List<String> _topTags(Map<String, List<String>> tagsByEntry, int limit) {
    final counts = <String, int>{};
    for (final list in tagsByEntry.values) {
      for (final tag in list) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => '${e.key}(${e.value})').toList();
  }

  List<String> _topTagsFor(
    List<Entry> entries,
    Map<String, List<String>> tagsByEntry,
    int limit,
  ) {
    final counts = <String, int>{};
    for (final entry in entries) {
      for (final tag in tagsByEntry[entry.id] ?? const <String>[]) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(limit).map((e) => e.key).toList();
  }

  String _tagVocabulary(Map<String, List<String>> tagsByEntry) {
    final names = <String>{};
    for (final list in tagsByEntry.values) {
      names.addAll(list);
    }
    if (names.isEmpty) return '（还没有标签）';
    final sorted = names.toList()..sort();
    return sorted.take(40).join('、');
  }

  String _rangeOf(List<Entry> all) {
    if (all.isEmpty) return '（空库）';
    var earliest = all.first.entryDate;
    var latest = all.first.entryDate;
    for (final entry in all) {
      if (entry.entryDate.isBefore(earliest)) earliest = entry.entryDate;
      if (entry.entryDate.isAfter(latest)) latest = entry.entryDate;
    }
    return '${_dateKey(earliest)} ~ ${_dateKey(latest)}';
  }

  String _capSize(String markdown, int maxBytes) {
    if (utf8.encode(markdown).length <= maxBytes) return markdown;
    final buffer = StringBuffer();
    for (final line in markdown.split('\n')) {
      final candidate = '${buffer.toString()}$line\n';
      if (utf8.encode(candidate).length > maxBytes - 80) break;
      buffer.writeln(line);
    }
    return '${buffer.toString().trimRight()}\n\n> 已按 ${maxBytes ~/ 1024} KB 预算截断。\n';
  }

  static String _firstLine(String body) {
    for (final line in body.split('\n')) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      return text;
    }
    return '';
  }

  static String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String _stamp(DateTime date) =>
      '${_dateKey(date)} ${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}
