import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/entry_repository.dart';
import '../data/tag_repository.dart';
import 'cloud_client.dart';
import 'rag_database.dart';

/// 一份已生成的 skill 文件。
class SkillEntry {
  const SkillEntry({
    required this.directory,
    required this.markdown,
    required this.createdAt,
    required this.model,
    required this.bytes,
  });

  final String directory;
  final String markdown;
  final DateTime createdAt;
  final String model;
  final int bytes;

  String get name => p.basename(directory);
}

class DistilledSkill {
  const DistilledSkill({
    required this.directory,
    required this.markdown,
    required this.model,
    required this.bytes,
    required this.entries,
    required this.createdAt,
  });

  final String directory;
  final String markdown;
  final String model;
  final int bytes;
  final int entries;
  final DateTime createdAt;

  String get file => p.join(directory, 'SKILL.md');

  Map<String, Object?> toJson() => <String, Object?>{
    'directory': directory,
    'file': file,
    'model': model,
    'bytes': bytes,
    'entries': entries,
    'createdAt': createdAt.toIso8601String(),
  };
}

/// 蒸馏器：把 soul.md + 语料摘要压成 skill。默认走云端。
abstract class SkillDistiller {
  String get modelId;

  Future<bool> isAvailable();

  Future<String> distill({required String soul, required String digest});
}

class SkillUnavailable implements Exception {
  SkillUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

class CloudSkillDistiller implements SkillDistiller {
  CloudSkillDistiller(this.config);

  final CloudConfig config;
  late final CloudCompleter _client = CloudCompleter(config, temperature: 0.4);

  @override
  String get modelId => _client.modelId;

  @override
  Future<bool> isAvailable() => _client.isAvailable();

  @override
  Future<String> distill({
    required String soul,
    required String digest,
  }) async {
    final prompt = buildPrompt(soul: soul, digest: digest);
    final text = await _client.complete(prompt, maxTokens: 1600);
    final cleaned = _stripFence(text).trim();
    if (cleaned.isEmpty) throw SkillUnavailable('云端返回了空 skill');
    return cleaned;
  }

  static String buildPrompt({required String soul, required String digest}) {
    return '你是一个「技能蒸馏器」。把下面这个人的日记库蒸馏成一个其他大模型可以直接加载的 skill。\n'
        '只依据材料，不要编造具体日期、金额、人名；不确定的地方写「不确定」。\n'
        '输出 Markdown，固定结构（不要输出其它内容）：\n'
        '# Skill: <一句话名字>\n'
        '> <一句话说明这个 skill 能做什么>\n'
        '## 何时使用\n'
        '## 这个人的画像\n'
        '## 常用事实与偏好\n'
        '## 检索与回答规则\n'
        '## 禁止事项\n'
        '总长度控制在 6000 字以内。\n\n'
        '=== soul.md ===\n$soul\n\n'
        '=== 语料摘要样本 ===\n$digest';
  }

  static String _stripFence(String content) {
    var text = content.trim();
    if (text.startsWith('```')) {
      final newline = text.indexOf('\n');
      if (newline >= 0) text = text.substring(newline + 1);
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
    }
    return text.trim();
  }
}

/// 测试 / 离线：输出结构完整的假 skill。
class FakeSkillDistiller implements SkillDistiller {
  FakeSkillDistiller({this.model = 'fake-skill'});

  final String model;

  @override
  String get modelId => 'fake:$model';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> distill({
    required String soul,
    required String digest,
  }) async {
    return '# Skill: MDiary 助手\n\n'
        '> 根据日记库蒸馏出的示范 skill。\n\n'
        '## 何时使用\n\n'
        '当用户询问过去的生活、工作、旅行记录时使用。\n\n'
        '## 这个人的画像\n\n'
        '（示范）一个记录日常生活的人。\n\n'
        '## 常用事实与偏好\n\n'
        '- 喜欢在日记里写具体地点和花费。\n'
        '- 常用标签：工作、旅行。\n\n'
        '## 检索与回答规则\n\n'
        '1. 先调用 `search_diary`，只根据命中片段回答。\n'
        '2. 每条事实标注 `[日期-标题]`。\n\n'
        '## 禁止事项\n\n'
        '- 不要编造没有出现在日记里的细节。\n'
        '- 不要把内容发送到未经用户授权的服务。\n';
  }
}

/// 蒸馏任务：读 soul.md + 语料摘要 → 云端生成 skill → 写到 `db/skill/<时间>/`。
///
/// 每次生成一个新目录，**从不覆盖**旧 skill。
class SkillJob {
  SkillJob({
    required this.rag,
    required this.entries,
    required this.tags,
    required this.distiller,
    this.maxBytes = 16 * 1024,
    this.maxSamples = 80,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RagDatabase rag;
  final EntryRepository entries;
  final TagRepository tags;
  final SkillDistiller distiller;
  final int maxBytes;
  final int maxSamples;
  final DateTime Function() _clock;

  /// `<库目录>/db/skill`。
  static String directoryFor(RagDatabase rag) =>
      p.join(p.dirname(p.dirname(rag.path)), 'db', 'skill');

  String get directory => directoryFor(rag);

  List<SkillEntry> list() => listIn(directory);

  static List<SkillEntry> listIn(String directory) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const <SkillEntry>[];
    final result = <SkillEntry>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'SKILL.md'));
      if (!file.existsSync()) continue;
      var model = '';
      var createdAt = file.lastModifiedSync();
      final metaFile = File(p.join(entity.path, 'meta.json'));
      if (metaFile.existsSync()) {
        try {
          final meta = jsonDecode(metaFile.readAsStringSync());
          if (meta is Map<String, dynamic>) {
            model = '${meta['model'] ?? ''}';
            final stamp = DateTime.tryParse('${meta['created_at'] ?? ''}');
            if (stamp != null) createdAt = stamp;
          }
        } on Object {
          // 坏 meta 不影响读取正文
        }
      }
      final markdown = file.readAsStringSync();
      result.add(
        SkillEntry(
          directory: entity.path,
          markdown: markdown,
          createdAt: createdAt,
          model: model,
          bytes: utf8.encode(markdown).length,
        ),
      );
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<DistilledSkill> run({String? soulMarkdown}) async {
    final soul = (soulMarkdown ?? _readSoul()).trim();
    if (soul.isEmpty) {
      throw SkillUnavailable('还没有 soul.md：先让灵魂档案生成一次，再蒸馏');
    }
    final digest = buildDigest();
    final body = await distiller.distill(soul: soul, digest: digest);
    final markdown = _compose(body, soulBytes: utf8.encode(soul).length);
    final created = _clock();
    final dir = _uniqueDirectory(created);
    Directory(dir).createSync(recursive: true);
    final file = File(p.join(dir, 'SKILL.md'));
    file.writeAsStringSync(markdown, flush: true);
    final meta = <String, Object?>{
      'name': 'mdiary-skill-${_stamp(created)}',
      'created_at': created.toIso8601String(),
      'model': distiller.modelId,
      'bytes': utf8.encode(markdown).length,
      'soul_bytes': utf8.encode(soul).length,
      'entries': entries.query().length,
      'samples': _samples().length,
      'tags': tags.allNames().length,
    };
    File(p.join(dir, 'meta.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(meta),
      flush: true,
    );
    return DistilledSkill(
      directory: dir,
      markdown: markdown,
      model: distiller.modelId,
      bytes: utf8.encode(markdown).length,
      entries: entries.query().length,
      createdAt: created,
    );
  }

  String buildDigest() {
    final samples = _samples();
    final buffer = StringBuffer()
      ..writeln('总篇数：${entries.query().length}')
      ..writeln('标签：${tags.allNames().take(20).join('、')}')
      ..writeln('样本：');
    for (final line in samples) {
      buffer.writeln('- $line');
    }
    return buffer.toString();
  }

  List<String> _samples() {
    final list = entries.query();
    list.sort((a, b) => b.entryDate.compareTo(a.entryDate));
    final result = <String>[];
    for (final entry in list.take(maxSamples)) {
      final summary = (rag.entrySummaryOf(entry.id) ?? '').trim();
      final text = summary.isNotEmpty ? summary : _firstLine(entry.bodyMd);
      final clipped = text.length <= 90 ? text : '${text.substring(0, 90)}…';
      final date =
          '${entry.entryDate.year}-${entry.entryDate.month.toString().padLeft(2, '0')}-'
          '${entry.entryDate.day.toString().padLeft(2, '0')}';
      result.add('$date《${entry.title.trim().isEmpty ? '无标题' : entry.title.trim()}》$clipped');
    }
    return result;
  }

  String _readSoul() {
    final file = File(p.join(p.dirname(p.dirname(rag.path)), 'rag', 'soul.md'));
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  String _compose(String body, {required int soulBytes}) {
    final stamp = _stamp(_clock());
    final name = 'mdiary-skill-$stamp';
    final description = _descriptionFrom(body);
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('name: $name')
      ..writeln('description: ${jsonEncode(description)}')
      ..writeln('generated_by: MDiary')
      ..writeln('model: ${distiller.modelId}')
      ..writeln('created_at: ${_clock().toIso8601String()}')
      ..writeln('source: soul.md + rag/index.sqlite')
      ..writeln('soul_bytes: $soulBytes')
      ..writeln('---')
      ..writeln()
      ..writeln(body.trim());
    final text = buffer.toString();
    if (utf8.encode(text).length <= maxBytes) return text;
    final lines = text.split('\n');
    final capped = StringBuffer();
    for (final line in lines) {
      final candidate = '${capped.toString()}$line\n';
      if (utf8.encode(candidate).length > maxBytes - 90) break;
      capped.writeln(line);
    }
    return '${capped.toString().trimRight()}\n\n'
        '> 已按 ${maxBytes ~/ 1024} KB 预算截断。\n';
  }

  static String _stamp(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}-'
      '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}';

  /// 从正文里挑一句当 description（给 DSH 这类 agent 做技能目录用）。
  static String _descriptionFrom(String body) {
    final lines = body.split('\n');
    for (final line in lines) {
      final text = line.trim();
      if (text.startsWith('>')) {
        final quote = text.substring(1).trim();
        if (quote.isNotEmpty) return _clip(quote, 160);
      }
    }
    for (final line in lines) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#') || text.startsWith('---')) {
        continue;
      }
      if (text.startsWith('-')) continue;
      return _clip(text, 160);
    }
    return 'MDiary 日记库蒸馏出的 skill';
  }

  static String _clip(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }

  String _uniqueDirectory(DateTime now) {
    final base = _stamp(now);
    var candidate = p.join(directory, base);
    if (!Directory(candidate).existsSync()) return candidate;
    for (var i = 2; i < 100; i++) {
      candidate = p.join(directory, '$base-$i');
      if (!Directory(candidate).existsSync()) return candidate;
    }
    return p.join(directory, '$base-${now.millisecondsSinceEpoch}');
  }

  static String _firstLine(String body) {
    for (final line in body.split('\n')) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      return text;
    }
    return '';
  }
}
