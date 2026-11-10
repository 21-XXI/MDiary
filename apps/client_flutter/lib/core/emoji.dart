/// 常用表情短代码（`:smile:` → 😄）。
///
/// 内置表只是默认值：用户可以在「表情」面板里新增或覆盖，覆盖项存在 meta 表
/// `emoji_custom`（JSON），不会改到这里。
const Map<String, String> builtinEmoji = <String, String>{
  'smile': '😄',
  'grin': '😁',
  'joy': '😂',
  'rofl': '🤣',
  'wink': '😉',
  'heart_eyes': '😍',
  'kissing_heart': '😘',
  'thinking': '🤔',
  'sweat_smile': '😅',
  'sob': '😭',
  'cry': '😢',
  'angry': '😠',
  'rage': '😡',
  'sleepy': '😴',
  'yum': '😋',
  'sunglasses': '😎',
  'mask': '😷',
  'poop': '💩',
  'thumbsup': '👍',
  'thumbsdown': '👎',
  'ok_hand': '👌',
  'clap': '👏',
  'pray': '🙏',
  'wave': '👋',
  'muscle': '💪',
  'point_right': '👉',
  'eyes': '👀',
  'brain': '🧠',
  'sparkles': '✨',
  'star': '⭐',
  'fire': '🔥',
  'heart': '❤️',
  'broken_heart': '💔',
  'blue_heart': '💙',
  'green_heart': '💚',
  'yellow_heart': '💛',
  'purple_heart': '💜',
  'tada': '🎉',
  'gift': '🎁',
  'cake': '🍰',
  'coffee': '☕',
  'beer': '🍺',
  'pizza': '🍕',
  'sun': '☀️',
  'moon': '🌙',
  'cloud': '☁️',
  'rain': '🌧️',
  'snow': '❄️',
  'rainbow': '🌈',
  'cat': '🐱',
  'dog': '🐶',
  'panda': '🐼',
  'bug': '🐛',
  'rocket': '🚀',
  'computer': '💻',
  'phone': '📱',
  'book': '📖',
  'pencil': '✏️',
  'memo': '📝',
  'calendar': '📅',
  'clock': '⏰',
  'money': '💰',
  'check': '✅',
  'x': '❌',
  'warning': '⚠️',
  'question': '❓',
  'exclamation': '❗',
  '100': '💯',
  'ok': '🆗',
  'new': '🆕',
  'free': '🆓',
  'cool': '🆒',
  'soon': '🔜',
  'top': '🔝',
  'up': '⬆️',
  'down': '⬇️',
  'left': '⬅️',
  'right': '➡️',
  // 中文别名
  '微笑': '😄',
  '大笑': '😂',
  '哭': '😭',
  '生气': '😠',
  '爱心': '❤️',
  '喜欢': '❤️',
  '赞': '👍',
  '点赞': '👍',
  '鼓掌': '👏',
  '加油': '💪',
  '庆祝': '🎉',
  '咖啡': '☕',
  '蛋糕': '🍰',
  '猫': '🐱',
  '狗': '🐶',
  '火': '🔥',
  '星星': '⭐',
  '彩虹': '🌈',
};

/// 把正文里的 `:code:` 替换成表情。
///
/// 跳过围栏代码块与行内代码；未知短代码原样保留。
String applyEmoji(String text, Map<String, String> mapping) {
  if (mapping.isEmpty || !text.contains(':')) return text;
  final buffer = StringBuffer();
  var i = 0;
  while (i < text.length) {
    if (text.startsWith('```', i)) {
      final end = text.indexOf('```', i + 3);
      final stop = end < 0 ? text.length : end + 3;
      buffer.write(text.substring(i, stop));
      i = stop;
      continue;
    }
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      final stop = end < 0 ? text.length : end + 1;
      buffer.write(text.substring(i, stop));
      i = stop;
      continue;
    }
    if (text[i] == ':') {
      final end = text.indexOf(':', i + 1);
      if (end > i + 1 && end - i <= 32) {
        final code = text.substring(i + 1, end);
        if (!RegExp(r'\s').hasMatch(code)) {
          final value = mapping[code];
          if (value != null) {
            buffer.write(value);
            i = end + 1;
            continue;
          }
        }
      }
    }
    buffer.write(text[i]);
    i++;
  }
  return buffer.toString();
}
