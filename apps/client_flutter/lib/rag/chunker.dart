import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 一个可被检索的最小单元：日记正文的一段，或一个附件的描述。
class RagChunk {
  const RagChunk({
    required this.kind,
    this.entryId,
    this.attachmentId,
    required this.ordinal,
    required this.text,
    required this.headingPath,
    required this.label,
    required this.sourceDate,
    required this.tokens,
    required this.hash,
  });

  /// `entry` 或 `attachment`。
  final String kind;
  final String? entryId;
  final String? attachmentId;
  final int ordinal;

  /// 存入索引的正文（带「标题/日期/标签/章节」前缀，便于检索与展示）。
  final String text;

  /// 所属章节路径（`H1 > H2`），空字符串表示没有标题。
  final String headingPath;

  /// 结果列表上的显示名：日记标题，或附件文件名。
  final String label;
  final DateTime sourceDate;
  final int tokens;
  final String hash;
}

/// Markdown 结构感知的切片器。
///
/// - 标题开新节，切片里保留「标题 > 小节」路径；
/// - 代码块整块保留，不按空行切；
/// - 单段过长时按行/句再切，保证不超过 [maxTokens]。
class MarkdownChunker {
  MarkdownChunker({this.targetTokens = 560, this.maxTokens = 800});

  final int targetTokens;
  final int maxTokens;

  List<RagChunk> chunkEntry({
    required String entryId,
    required String title,
    required DateTime date,
    required String body,
    List<String> tags = const <String>[],
  }) {
    final header = entryHeader(title: title, date: date, tags: tags);
    final sections = _splitSections(body);
    final chunks = <RagChunk>[];
    var ordinal = 0;

    for (final section in sections) {
      for (final block in _packBlocks(section.blocks)) {
        final text = StringBuffer(header);
        if (section.path.isNotEmpty) {
          text.write('\n章节：${section.path}');
        }
        text
          ..write('\n\n')
          ..write(block);
        final content = text.toString();
        chunks.add(
          RagChunk(
            kind: 'entry',
            entryId: entryId,
            ordinal: ordinal++,
            text: content,
            headingPath: section.path,
            label: title.trim().isEmpty ? '无标题' : title.trim(),
            sourceDate: date,
            tokens: estimateTokens(content),
            hash: contentHash(content),
          ),
        );
      }
    }

    if (chunks.isEmpty) {
      final content = '$header\n\n正文：（空）';
      chunks.add(
        RagChunk(
          kind: 'entry',
          entryId: entryId,
          ordinal: 0,
          text: content,
          headingPath: '',
          label: title.trim().isEmpty ? '无标题' : title.trim(),
          sourceDate: date,
          tokens: estimateTokens(content),
          hash: contentHash(content),
        ),
      );
    }
    return chunks;
  }

  /// 附件切片：元数据 +（可选）抽取出的文本。
  List<RagChunk> chunkAttachment({
    required String attachmentId,
    required String entryId,
    required String filename,
    required String mime,
    required int sizeBytes,
    required String entryTitle,
    required DateTime date,
    String? extractedText,
  }) {
    final head =
        '附件：$filename\n'
        '类型：$mime · ${formatSize(sizeBytes)}\n'
        '所属日记：《${entryTitle.trim().isEmpty ? '无标题' : entryTitle.trim()}》（${formatDate(date)}）';
    final body = (extractedText ?? '').trim();
    final text = body.isEmpty ? head : '$head\n\n$body';
    final blocks = body.isEmpty ? <String>[head] : <String>[head, body];

    final chunks = <RagChunk>[];
    var ordinal = 0;
    for (final block in _packBlocks(blocks)) {
      final content = block.startsWith('附件：') ? block : '$head\n\n$block';
      chunks.add(
        RagChunk(
          kind: 'attachment',
          entryId: entryId,
          attachmentId: attachmentId,
          ordinal: ordinal++,
          text: content,
          headingPath: '',
          label: filename,
          sourceDate: date,
          tokens: estimateTokens(content),
          hash: contentHash(content),
        ),
      );
    }
    if (chunks.isEmpty) {
      chunks.add(
        RagChunk(
          kind: 'attachment',
          entryId: entryId,
          attachmentId: attachmentId,
          ordinal: 0,
          text: text,
          headingPath: '',
          label: filename,
          sourceDate: date,
          tokens: estimateTokens(text),
          hash: contentHash(text),
        ),
      );
    }
    return chunks;
  }

  static String entryHeader({
    required String title,
    required DateTime date,
    List<String> tags = const <String>[],
  }) {
    final buffer = StringBuffer('《${title.trim().isEmpty ? '无标题' : title.trim()}》${formatDate(date)}');
    if (tags.isNotEmpty) buffer.write(' · 标签：${tags.join('、')}');
    return buffer.toString();
  }

  /// 粗估 token：中日韩字符按 1 个算，其它字符按 4 个算 1 个。
  static int estimateTokens(String text) {
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) continue;
      if (_isWide(rune)) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other / 4).ceil();
  }

  static bool _isWide(int rune) =>
      (rune >= 0x2E80 && rune <= 0x9FFF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFF00 && rune <= 0xFFEF) ||
      (rune >= 0x3040 && rune <= 0x30FF);

  static String contentHash(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  List<_Section> _splitSections(String body) {
    final sections = <_Section>[];
    var current = _Section('');
    final levels = <int, String>{};
    final paragraph = <String>[];
    var inFence = false;

    void flushParagraph() {
      final text = paragraph.join('\n').trimRight();
      paragraph.clear();
      if (text.trim().isNotEmpty) current.blocks.add(text);
    }

    void flushSection() {
      flushParagraph();
      if (current.blocks.isNotEmpty) sections.add(current);
    }

    for (final line in body.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        paragraph.add(line);
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        paragraph.add(line);
        continue;
      }

      final heading = _headingPattern.firstMatch(line);
      if (heading != null) {
        flushSection();
        final level = heading.group(1)!.length;
        final title = heading.group(2)!.trim();
        levels.removeWhere((key, _) => key >= level);
        levels[level] = title;
        final path = (levels.keys.toList()..sort())
            .map((key) => levels[key]!)
            .join(' > ');
        current = _Section(path);
        continue;
      }

      if (line.trim().isEmpty) {
        flushParagraph();
      } else {
        paragraph.add(line);
      }
    }
    flushSection();
    return sections;
  }

  static final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');

  List<String> _packBlocks(List<String> blocks) {
    final out = <String>[];
    final buffer = <String>[];
    var tokens = 0;

    void flush() {
      if (buffer.isEmpty) return;
      out.add(buffer.join('\n\n'));
      buffer.clear();
      tokens = 0;
    }

    for (final raw in blocks) {
      for (final block in _splitLong(raw)) {
        final size = estimateTokens(block);
        if (buffer.isNotEmpty && tokens + size > targetTokens) flush();
        buffer.add(block);
        tokens += size;
        if (tokens >= targetTokens) flush();
      }
    }
    flush();
    return out;
  }

  /// 单块超过 [maxTokens] 时按行切成几段（代码块也按行切，尽量保持完整）。
  List<String> _splitLong(String block) {
    if (estimateTokens(block) <= maxTokens) return <String>[block];
    final out = <String>[];
    final buffer = <String>[];
    var tokens = 0;
    void flush() {
      if (buffer.isEmpty) return;
      out.add(buffer.join('\n'));
      buffer.clear();
      tokens = 0;
    }

    for (final line in block.split('\n')) {
      final size = estimateTokens(line);
      if (buffer.isNotEmpty && tokens + size > targetTokens) flush();
      buffer.add(line);
      tokens += size;
    }
    flush();
    return out.isEmpty ? <String>[block] : out;
  }

  static String formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _Section {
  _Section(this.path);

  final String path;
  final List<String> blocks = <String>[];
}
