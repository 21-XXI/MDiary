import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 一条记忆对话消息。
class MemoryMessage {
  const MemoryMessage({
    required this.fromUser,
    required this.text,
    required this.createdAt,
  });

  final bool fromUser;
  final String text;
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'from_user': fromUser,
    'text': text,
    'at': createdAt.toIso8601String(),
  };

  factory MemoryMessage.fromJson(Map<String, dynamic> json) => MemoryMessage(
    fromUser: json['from_user'] == true,
    text: '${json['text'] ?? ''}',
    createdAt:
        DateTime.tryParse('${json['at'] ?? ''}') ?? DateTime.now(),
  );
}

/// 按库持久化（JSONL，一行一条），换库各自独立。
class MemoryChatStore {
  const MemoryChatStore(this.path);

  final String path;

  List<MemoryMessage> load() {
    final file = File(path);
    if (!file.existsSync()) return const <MemoryMessage>[];
    final messages = <MemoryMessage>[];
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          messages.add(MemoryMessage.fromJson(decoded));
        }
      } on FormatException {
        // 坏行跳过
      }
    }
    return messages;
  }

  void append(MemoryMessage message) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode(message.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  void clear() {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  /// 跟 skill 放在一起，便于整库导出/备份。
  static String pathFor(String libraryDir) =>
      p.join(libraryDir, 'agent', 'chat.jsonl');
}

/// 记忆对话提示词：skill 是唯一的人设/知识来源（按用户选择，不检索日记）。
String buildMemoryPrompt({
  required String skill,
  required List<MemoryMessage> history,
  required String question,
}) {
  final buffer = StringBuffer()
    ..writeln('你在扮演日记主人的「记忆助手」。')
    ..writeln('下面是从日记库蒸馏出的 skill，它是你唯一的人设与事实来源：')
    ..writeln('=== skill 开始 ===')
    ..writeln(skill)
    ..writeln('=== skill 结束 ===')
    ..writeln()
    ..writeln('规则：')
    ..writeln('1. 只根据 skill 与对话回答，不要编造具体日期、金额、人名；')
    ..writeln('2. skill 里没有的信息，直接说「skill 里没有提到」，不要猜；')
    ..writeln('3. 用第一人称、口语化中文回答，控制在 200 字以内；')
    ..writeln('4. 可以追问，但不要主动索取隐私。')
    ..writeln();
  if (history.isNotEmpty) {
    buffer.writeln('最近的对话：');
    for (final message in history.reversed.take(20).toList().reversed) {
      buffer.writeln('${message.fromUser ? '用户' : '助手'}：${message.text}');
    }
    buffer.writeln();
  }
  buffer.writeln('用户：$question');
  return buffer.toString();
}
