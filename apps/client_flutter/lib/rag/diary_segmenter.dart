import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 一天里的一篇附加笔记。
class SegmentNote {
  const SegmentNote({required this.filename, required this.body});

  final String filename;
  final String body;
}

/// 分词后的一天。
class SegmentDay {
  const SegmentDay({
    required this.date,
    required this.title,
    required this.body,
    required this.tags,
    required this.attachments,
    this.notes = const <SegmentNote>[],
  });

  final DateTime date;
  final String title;
  final String body;
  final List<String> tags;
  final List<String> attachments;
  final List<SegmentNote> notes;

  int get chars => body.replaceAll(RegExp(r'\s'), '').length;
}

class SegmentPlan {
  const SegmentPlan({required this.days, required this.warnings});

  final List<SegmentDay> days;
  final List<String> warnings;

  int get attachments => days.fold(0, (sum, day) => sum + day.attachments.length);
}

/// 把文件夹资料交给模型切分成日记。纯逻辑，模型调用通过 [complete] 注入。
class DiarySegmenter {
  DiarySegmenter({
    required this.complete,
    this.maxFiles = 200,
    this.maxChars = 60000,
  });

  final Future<String> Function(String prompt) complete;
  final int maxFiles;
  final int maxChars;

  Future<SegmentPlan> planDirectory(String directory) async {
    final root = Directory(directory);
    if (!await root.exists()) {
      throw const SegmenterException('文件夹不存在');
    }
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.md') && !lower.endsWith('.txt')) continue;
      final stat = await entity.stat();
      if (stat.size > 2 * 1024 * 1024) continue;
      files.add(entity);
      if (files.length >= maxFiles) break;
    }
    if (files.isEmpty) {
      throw const SegmenterException('这个文件夹里没有 .md / .txt');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final buffer = StringBuffer();
    final names = <String>{};
    for (final file in files) {
      final text = await file.readAsString();
      final relative = p.relative(file.path, from: root.path);
      names.add(p.basename(file.path));
      buffer
        ..writeln('===== 文件：$relative =====')
        ..writeln(text)
        ..writeln();
      if (buffer.length > maxChars) break;
    }
    final prompt = _buildPrompt(buffer.toString(), files.length);
    final raw = await complete(prompt);
    return parsePlan(raw, availableAttachments: names);
  }

  static String _buildPrompt(String material, int fileCount) {
    return '你是日记整理器。把下面 $fileCount 个文件按日期切分成日记，输出严格 JSON（不要输出其它内容）：\n'
        '{"days":[{"date":"YYYY-MM-DD","title":"标题","body":"第一人称日记正文",'
        '"tags":["标签"],"attachments":["文件名"]}]}\n'
        '规则：\n'
        '1. 只依据材料，不要编造日期、金额、人名；无法确定日期时用材料里最早的日期；\n'
        '2. 同一天的多段材料合并成一篇，不要按段落拆成多篇；\n'
        '3. 第一人称日记体，保留具体人名、地点、金额；不要写「根据材料」之类元话语；\n'
        '4. attachments 只填材料里出现过的文件名（图片/PDF），没有就空数组；\n'
        '5. 正文 200–1500 字。\n\n'
        '===== 材料 =====\n$material';
  }

  static SegmentPlan parsePlan(
    String raw, {
    Set<String> availableAttachments = const <String>{},
  }) {
    final warnings = <String>[];
    final text = _stripFence(raw);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const SegmenterException('模型没有返回合法 JSON，请重试或换模型');
    }
    if (decoded is! Map || decoded['days'] is! List) {
      throw const SegmenterException('模型返回的 JSON 缺少 days 数组');
    }
    final days = <SegmentDay>[];
    final seen = <String>{};
    for (final item in decoded['days'] as List) {
      if (item is! Map) continue;
      final dateText = '${item['date'] ?? ''}'.trim();
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateText);
      if (match == null) {
        warnings.add('跳过无法解析的日期：$dateText');
        continue;
      }
      final date = DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      );
      final body = '${item['body'] ?? ''}'.trim();
      if (body.isEmpty) {
        warnings.add('$dateText 正文为空，已跳过');
        continue;
      }
      if (!seen.add(dateText)) {
        warnings.add('$dateText 重复，只保留第一篇');
        continue;
      }
      final tags = <String>[];
      final rawTags = item['tags'];
      if (rawTags is List) {
        for (final tag in rawTags) {
          final value = '$tag'.trim();
          if (value.isNotEmpty) tags.add(value);
        }
      }
      final attachments = <String>[];
      final rawAttachments = item['attachments'];
      if (rawAttachments is List) {
        for (final attachment in rawAttachments) {
          final name = p.basename('$attachment'.trim());
          if (name.isEmpty) continue;
          if (availableAttachments.isNotEmpty &&
              !availableAttachments.contains(name)) {
            warnings.add('附件不在资料里：$name');
            continue;
          }
          if (!attachments.contains(name)) attachments.add(name);
        }
      }
      final notes = <SegmentNote>[];
      final rawNotes = item['notes'];
      if (rawNotes is List) {
        for (final rawNote in rawNotes) {
          if (rawNote is! Map) continue;
          final filename = p.basename('${rawNote['filename'] ?? ''}'.trim());
          final body = '${rawNote['body'] ?? ''}'.trim();
          if (filename.isEmpty || body.isEmpty) continue;
          notes.add(
            SegmentNote(
              filename: filename.toLowerCase().endsWith('.md')
                  ? filename
                  : '$filename.md',
              body: body,
            ),
          );
        }
      }
      days.add(
        SegmentDay(
          date: date,
          title: '${item['title'] ?? ''}'.trim().isEmpty
              ? dateText
              : '${item['title']}'.trim(),
          body: body,
          tags: tags,
          attachments: attachments,
          notes: notes,
        ),
      );
    }
    days.sort((a, b) => a.date.compareTo(b.date));
    if (days.isEmpty) {
      throw const SegmenterException('没有切出任何一天，检查资料里有没有日期线索');
    }
    return SegmentPlan(days: days, warnings: warnings);
  }

  static String _stripFence(String content) {
    var text = content.trim();
    if (text.startsWith('```')) {
      final newline = text.indexOf('\n');
      if (newline >= 0) text = text.substring(newline + 1);
      if (text.endsWith('```')) text = text.substring(0, text.length - 3);
    }
    return text.trim();
  }
}

class SegmenterException implements Exception {
  const SegmenterException(this.message);

  final String message;

  @override
  String toString() => message;
}
