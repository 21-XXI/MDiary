/// 轻量格式化工具：不引入 intl，避免额外依赖与本地化数据加载。
library;

const List<String> _weekdays = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

String _two(int v) => v.toString().padLeft(2, '0');

/// 2026-11-02
String formatDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

/// 11月2日 周一
String formatDayLabel(DateTime t) {
  final weekday = _weekdays[(t.weekday - 1) % 7];
  return '${t.month}月${t.day}日 $weekday';
}

/// 2026-11-02 11:20
String formatDateTime(DateTime t) =>
    '${formatDate(t)} ${_two(t.hour)}:${_two(t.minute)}';

/// 11:20 / 昨天 11:20 / 2026-11-02
String formatRelative(DateTime t, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '${_two(t.hour)}:${_two(t.minute)}';
  if (diff == 1) return '昨天 ${_two(t.hour)}:${_two(t.minute)}';
  if (diff > 1 && diff < 7) return '$diff 天前';
  return formatDate(t);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 正文字数：非空白字符数（中英文都按单字计）。
int countCharacters(String text) {
  var count = 0;
  for (final rune in text.runes) {
    if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) continue;
    count++;
  }
  return count;
}

/// 从正文首行推导标题（用于未填标题的条目）。
String deriveTitleFromBody(String body) {
  for (final rawLine in body.split('\n')) {
    final line = rawLine.trim().replaceAll(RegExp(r'^#{1,6}\s*'), '').trim();
    if (line.isEmpty) continue;
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }
  return '无标题';
}
