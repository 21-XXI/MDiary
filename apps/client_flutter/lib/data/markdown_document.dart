/// Markdown 文档的纯逻辑部分（无 IO、无数据库），便于单测。
library;

/// 解析结果：front matter 键值 + 正文。
class MarkdownDocument {
  const MarkdownDocument({required this.meta, required this.body});

  final Map<String, String> meta;
  final String body;

  String? get title {
    final value = meta['title']?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  DateTime? get date => parseDate(meta['date']);

  List<String> get tags {
    final raw = meta['tags']?.trim();
    if (raw == null || raw.isEmpty) return const <String>[];
    final cleaned = raw.replaceAll('[', '').replaceAll(']', '');
    return cleaned
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }
}

/// 解析 YAML front matter（只支持本程序会写出的扁平 `key: value` 子集）。
MarkdownDocument parseMarkdownDocument(
  String content, {
  String debugName = '',
}) {
  var text = content;
  if (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }
  final normalized = text.replaceAll('\r\n', '\n');
  if (!normalized.startsWith('---')) {
    return MarkdownDocument(meta: const <String, String>{}, body: normalized);
  }
  final lines = normalized.split('\n');
  var endIndex = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      endIndex = i;
      break;
    }
  }
  if (endIndex < 0) {
    return MarkdownDocument(meta: const <String, String>{}, body: normalized);
  }
  final meta = <String, String>{};
  for (var i = 1; i < endIndex; i++) {
    final line = lines[i];
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    var value = line.substring(colon + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      final quote = value[0];
      value = value.substring(1, value.length - 1);
      if (quote == '"') {
        value = _unescapeDoubleQuoted(value);
      }
    }
    if (key.isNotEmpty) meta[key] = value;
  }
  final body = lines.sublist(endIndex + 1).join('\n');
  return MarkdownDocument(
    meta: meta,
    body: body.replaceFirst(RegExp(r'^\n'), ''),
  );
}

DateTime? parseDate(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  // 先按纯日期解析并做范围校验：DateTime 会把 2026-13-40 规范化成 2027-02-09，
  // 这种「看起来解析成功」的脏数据必须拒绝。
  final match = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$')
      .firstMatch(trimmed);
  if (match != null) {
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }
  final iso = DateTime.tryParse(trimmed);
  if (iso == null) return null;
  // 带时间的 ISO 串同样校验月/日是否被规范化
  final head = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(trimmed);
  if (head != null) {
    if (iso.month != int.parse(head.group(2)!) ||
        iso.day != int.parse(head.group(3)!)) {
      return null;
    }
  }
  return iso;
}

/// 生成带 front matter 的 .md 文本；正文原样保留（仅统一换行为 LF）。
String buildMarkdownDocument({
  required String title,
  required DateTime date,
  List<String> tags = const <String>[],
  required String body,
}) {
  final normalizedBody = body.replaceAll('\r\n', '\n').trimRight();
  final buffer = StringBuffer()
    ..writeln('---')
    ..writeln('title: ${_quote(title)}')
    ..writeln(
      'date: ${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}',
    );
  if (tags.isNotEmpty) {
    buffer.writeln('tags: [${tags.join(', ')}]');
  }
  buffer
    ..writeln('---')
    ..writeln()
    ..write(normalizedBody)
    ..writeln();
  return buffer.toString();
}

String _quote(String value) {
  // 含 YAML 敏感字符（: # " \）或首尾空格时必须加双引号，否则会被误解析
  final needsQuote =
      value.contains(':') ||
      value.contains('#') ||
      value.contains('"') ||
      value.contains('\\') ||
      value != value.trim();
  if (!needsQuote) return value;
  final escaped = value.replaceAll('\\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

/// 解析双引号包裹的值：还原 `\"` 与 `\\`（与 [_quote] 对称）。
String _unescapeDoubleQuoted(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (char == '\\' && i + 1 < value.length) {
      final next = value[i + 1];
      if (next == '"' || next == '\\') {
        buffer.write(next);
        i++;
        continue;
      }
    }
    buffer.write(char);
  }
  return buffer.toString();
}

/// 导出文件名：`2026-11-02-标题.md`，去掉 Windows 非法字符。
String safeFileName(DateTime date, String title, {String suffix = ''}) {
  final datePart =
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  var clean = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Windows 不允许文件名以点或空格结尾
  clean = clean.replaceAll(RegExp(r'[. ]+$'), '');
  if (clean.isEmpty) clean = '无标题';
  if (clean.length > 60) clean = clean.substring(0, 60).trim();
  return '$datePart-$clean$suffix.md';
}

/// 正文中的图片/链接引用正则（`![](path)`，允许 title）。
final RegExp markdownLinkPattern = RegExp(
  r'(!?)\[([^\]]*)\]\(\s*([^)\s]+)(\s+"[^"]*")?\s*\)',
);

bool isRemoteReference(String ref) {
  final lower = ref.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('//');
}

/// 把正文里指向本地文件的相对引用改写为 `assets/<hash><ext>`。
/// [resolver] 返回新的相对引用；返回 null 表示保持原样。
String rewriteLocalReferences(
  String body,
  String? Function(String rawRef) resolver,
) {
  return body.replaceAllMapped(markdownLinkPattern, (match) {
    final raw = match.group(3)!;
    if (isRemoteReference(raw)) return match.group(0)!;
    final replacement = resolver(raw);
    if (replacement == null) return match.group(0)!;
    final titlePart = match.group(4) ?? '';
    return '${match.group(1)}[${match.group(2)}](assets/$replacement$titlePart)';
  });
}

/// 从正文中提取所有本地图片引用（去重）。
Set<String> extractLocalReferences(String body) {
  final result = <String>{};
  for (final match in markdownLinkPattern.allMatches(body)) {
    final raw = match.group(3)!;
    if (isRemoteReference(raw)) continue;
    result.add(raw);
  }
  return result;
}
