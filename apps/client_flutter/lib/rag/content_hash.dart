import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/models.dart';

/// 条目内容指纹：标题 + 正文 + 日期 + 标签。
///
/// 索引（chunk）与摘要（entry_summary）用同一个指纹，保证「改没改」判断一致。
String entryContentHash(Entry entry, List<String> tags) {
  final payload = <String>[
    entry.title,
    entry.bodyMd,
    entry.entryDate.toIso8601String(),
    tags.join(','),
  ].join('\n');
  return sha256.convert(utf8.encode(payload)).toString();
}

/// 附件内容指纹：文件名 + mime + 大小 + 抽出的文本。
String attachmentContentHash({
  required String filename,
  required String mime,
  required int sizeBytes,
  String? text,
}) {
  final payload = <String>[filename, mime, '$sizeBytes', text ?? ''].join('\n');
  return sha256.convert(utf8.encode(payload)).toString();
}
