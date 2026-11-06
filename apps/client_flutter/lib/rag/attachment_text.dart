import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:path/path.dart' as p;

/// 可以直接抽文本的附件类型（其余只索引元数据）。
const Set<String> textLikeExtensions = <String>{
  'txt',
  'text',
  'md',
  'markdown',
  'csv',
  'tsv',
  'json',
  'jsonl',
  'log',
  'yml',
  'yaml',
  'xml',
  'html',
  'htm',
  'css',
  'js',
  'mjs',
  'ts',
  'dart',
  'py',
  'go',
  'java',
  'kt',
  'c',
  'h',
  'cpp',
  'hpp',
  'cs',
  'rs',
  'rb',
  'php',
  'sql',
  'sh',
  'bash',
  'ps1',
  'bat',
  'ini',
  'toml',
  'cfg',
  'conf',
  'properties',
};

/// 读取文本类附件的正文；二进制/PDF 等返回 null（只索引元数据）。
///
/// [maxBytes] 限制读入量，避免一个超大日志把内存吃满。
Future<String?> extractAttachmentText(
  String path, {
  int maxBytes = 200 * 1024,
}) async {
  if (path.isEmpty) return null;
  final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (!textLikeExtensions.contains(extension)) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  final length = await file.length();
  final end = length < maxBytes ? length : maxBytes;
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, end)) {
    builder.add(chunk);
  }
  try {
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  } on Object {
    return null;
  }
}
