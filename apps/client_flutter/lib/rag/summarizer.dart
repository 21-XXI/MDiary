import 'dart:convert';
import 'dart:io';

/// 小模型给出的日记摘要与标签建议。
class EntrySummary {
  const EntrySummary({required this.summary, required this.tags});

  final String summary;
  final List<String> tags;

  Map<String, Object?> toJson() => <String, Object?>{
    'summary': summary,
    'tags': tags,
  };
}

/// 日报里的一条记录（给模型看的精简版）。
class ReportInput {
  const ReportInput({
    required this.title,
    required this.date,
    required this.summary,
    required this.body,
  });

  final String title;
  final DateTime date;
  final String summary;
  final String body;
}

/// 灵魂档案里需要模型写的几段（其余小节由程序按统计生成）。
class SoulSections {
  const SoulSections({
    required this.person,
    required this.themes,
    required this.peoplePlaces,
    required this.style,
    required this.recent,
  });

  final String person;
  final String themes;
  final String peoplePlaces;
  final String style;
  final String recent;
}

/// 摘要 / 日报生成器：默认本地 Ollama；测试用 [FakeSummarizer]。
abstract class Summarizer {
  String get modelId;

  Future<bool> isAvailable();

  Future<EntrySummary> summarize({
    required String title,
    required DateTime date,
    required String body,
    required List<String> tags,
  });

  /// 根据当天记录写一份 Markdown 日报。
  Future<String> generateReport({
    required DateTime date,
    required List<ReportInput> items,
    required List<String> attachments,
  });

  /// 根据「统计 + 摘要样本」概括这个人和这个库（soul.md 的语义部分）。
  Future<SoulSections> generateSoul({required String digest});
}

class SummarizerUnavailable implements Exception {
  SummarizerUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本地 Ollama 的对话接口（`/api/chat`）。
class OllamaSummarizer implements Summarizer {
  OllamaSummarizer({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model = 'qwen3:8b',
    this.timeout = const Duration(minutes: 3),
    this.maxBodyChars = 6000,
  });

  final String baseUrl;
  final String model;
  final Duration timeout;
  final int maxBodyChars;

  @override
  String get modelId => 'ollama:$model';

  @override
  Future<bool> isAvailable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl/api/tags'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(body);
      final models = decoded is Map ? decoded['models'] : null;
      if (models is! List) return true;
      return models.any((item) {
        final name = item is Map ? '${item['name'] ?? ''}' : '';
        return name == model || name.startsWith('$model:');
      });
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<EntrySummary> summarize({
    required String title,
    required DateTime date,
    required String body,
    required List<String> tags,
  }) async {
    final prompt = buildPrompt(
      title: title,
      date: date,
      body: body,
      tags: tags,
      maxBodyChars: maxBodyChars,
    );
    final content = await _chat(prompt, jsonFormat: true, temperature: 0.2);
    return parseSummary(content);
  }

  @override
  Future<String> generateReport({
    required DateTime date,
    required List<ReportInput> items,
    required List<String> attachments,
  }) async {
    final prompt = buildReportPrompt(
      date: date,
      items: items,
      attachments: attachments,
    );
    final content = await _chat(prompt, jsonFormat: false, temperature: 0.3);
    final text = stripFence(content);
    if (text.isEmpty) throw SummarizerUnavailable('模型返回了空日报');
    return text;
  }

  @override
  Future<SoulSections> generateSoul({required String digest}) async {
    final prompt = buildSoulPrompt(digest);
    final content = await _chat(prompt, jsonFormat: true, temperature: 0.4);
    final decoded = parseJsonObject(content);
    String pick(String key) {
      final value = '${decoded[key] ?? ''}'.trim();
      return value.isEmpty ? '（模型没有给出）' : value;
    }

    return SoulSections(
      person: pick('person'),
      themes: pick('themes'),
      peoplePlaces: pick('people_places'),
      style: pick('style'),
      recent: pick('recent'),
    );
  }

  static String buildSoulPrompt(String digest) =>
      '你是一个日记库的「灵魂档案」整理器。下面是一个人的日记统计与摘要样本，'
      '请概括这个人和这个库，输出严格 JSON（不要输出其它内容）：\n'
      '{"person": "身份/职业/生活状态/价值观，1-4 句", '
      '"themes": "长期反复出现的主题，1-4 句", '
      '"people_places": "重要的人、地点、项目，1-4 句", '
      '"style": "写作与表达的特点，1-3 句", '
      '"recent": "最近 30 天的状态，1-3 句"}\n'
      '要求：只依据材料，具体、克制，不要编造；看不出来就写"看不出来"。\n\n'
      '$digest';

  static Map<String, dynamic> parseJsonObject(String content) {
    final text = content.trim();
    if (text.isEmpty) throw SummarizerUnavailable('模型返回了空内容');
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // 尝试从文本里捞第一个 JSON 对象
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final value = jsonDecode(text.substring(start, end + 1));
        if (value is Map<String, dynamic>) return value;
      } on FormatException {
        // 落到下面抛错
      }
    }
    throw SummarizerUnavailable('模型没有返回合法 JSON：${_short(text)}');
  }

  Future<String> _chat(
    String prompt, {
    required bool jsonFormat,
    required double temperature,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/api/chat'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object>{
          'model': model,
          'stream': false,
          if (jsonFormat) 'format': 'json',
          'options': <String, Object>{'temperature': temperature},
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': prompt},
          ],
        }),
      );
      final response = await request.close().timeout(timeout);
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw SummarizerUnavailable(
          'Ollama 返回 ${response.statusCode}：${_short(raw)}（模型 $model 是否已拉取？）',
        );
      }
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? (decoded['message'] is Map
                ? '${(decoded['message'] as Map)['content'] ?? ''}'
                : '')
          : '';
    } on SocketException catch (error) {
      throw SummarizerUnavailable(
        '连不上本地 Ollama（$baseUrl）：${error.message}。'
        '先安装 Ollama 并执行 `ollama pull $model`。',
      );
    } on HttpException catch (error) {
      throw SummarizerUnavailable('本地 Ollama 请求失败：${error.message}');
    } on FormatException {
      throw SummarizerUnavailable('Ollama 响应不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }

  static String buildPrompt({
    required String title,
    required DateTime date,
    required String body,
    required List<String> tags,
    int maxBodyChars = 6000,
  }) {
    final truncated = body.length <= maxBodyChars
        ? body
        : '${body.substring(0, maxBodyChars)}\n……（后文已截断）';
    return '你是一个日记整理助手。请阅读这篇日记，输出严格 JSON（不要输出其它内容）：\n'
        '{"summary": "1-2 句中文摘要，不超过 80 字，只概括事实", '
        '"tags": ["2-4 个短标签"]}\n\n'
        '日期：${formatDate(date)}\n'
        '标题：${title.trim().isEmpty ? '（无标题）' : title.trim()}\n'
        '已有标签：${tags.isEmpty ? '（无）' : tags.join('、')}\n'
        '正文：\n$truncated';
  }

  static String buildReportPrompt({
    required DateTime date,
    required List<ReportInput> items,
    required List<String> attachments,
    int maxBodyChars = 320,
  }) {
    final buffer = StringBuffer()
      ..writeln('你是日记整理助手。请根据这一天的记录，写一份中文 Markdown 日报，')
      ..writeln('必须使用下面三个二级标题（顺序不变）：')
      ..writeln('## 今天写了什么')
      ..writeln('## 关键点 / 待办')
      ..writeln('## 一句话总结')
      ..writeln('要求：只依据提供的记录，不要编造；每条可以用 [日期-标题] 标注来源；')
      ..writeln('语气克制，不要空洞抒情。不要输出与日报无关的内容。')
      ..writeln()
      ..writeln('日期：${formatDate(date)}');
    for (final item in items) {
      final body = item.body.length <= maxBodyChars
          ? item.body
          : '${item.body.substring(0, maxBodyChars)}…';
      buffer
        ..writeln()
        ..writeln('- 《${item.title.trim().isEmpty ? '无标题' : item.title.trim()}》')
        ..writeln(
          '  摘要：${item.summary.trim().isEmpty ? '（无）' : item.summary.trim()}',
        )
        ..writeln('  正文摘录：${body.replaceAll(RegExp(r'\s+'), ' ').trim()}');
    }
    if (attachments.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('当天附件：${attachments.join('、')}');
    }
    return buffer.toString();
  }

  static EntrySummary parseSummary(String content) {
    final text = content.trim();
    if (text.isEmpty) throw SummarizerUnavailable('模型返回了空内容');
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) decoded = value;
    } on FormatException {
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          final value = jsonDecode(text.substring(start, end + 1));
          if (value is Map<String, dynamic>) decoded = value;
        } on FormatException {
          decoded = null;
        }
      }
    }
    if (decoded == null) {
      throw SummarizerUnavailable('模型没有返回合法 JSON：${_short(text)}');
    }
    final summary = '${decoded['summary'] ?? ''}'.trim();
    final rawTags = decoded['tags'];
    final tags = <String>[];
    if (rawTags is List) {
      for (final item in rawTags) {
        final tag = '$item'.trim();
        if (tag.isEmpty) continue;
        if (tags.any((existing) => existing.toLowerCase() == tag.toLowerCase())) {
          continue;
        }
        tags.add(tag);
      }
    }
    return EntrySummary(
      summary: summary.isEmpty ? '（模型没有给出摘要）' : summary,
      tags: tags.take(4).toList(growable: false),
    );
  }

  /// 去掉模型偶尔包在外面的 ``` 代码围栏。
  static String stripFence(String content) {
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

  static String formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String _short(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// 测试/离线用：确定性输出，不打网络。
class FakeSummarizer implements Summarizer {
  FakeSummarizer({this.model = 'fake'});

  final String model;

  @override
  String get modelId => 'fake:$model';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<EntrySummary> summarize({
    required String title,
    required DateTime date,
    required String body,
    required List<String> tags,
  }) async {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = flat.length <= 40 ? flat : '${flat.substring(0, 40)}…';
    return EntrySummary(
      summary: '${title.trim().isEmpty ? '无标题' : title.trim()}：$preview',
      tags: <String>[...tags.take(2), '自动整理'],
    );
  }

  @override
  Future<SoulSections> generateSoul({required String digest}) async =>
      const SoulSections(
        person: '（示范）一个在记录生活的人。',
        themes: '（示范）工作、旅行、阅读。',
        peoplePlaces: '（示范）杭州、同事、家人。',
        style: '（示范）短句，少修饰。',
        recent: '（示范）最近在整理旧日记。',
      );

  @override
  Future<String> generateReport({
    required DateTime date,
    required List<ReportInput> items,
    required List<String> attachments,
  }) async {
    final buffer = StringBuffer('## 今天写了什么\n\n');
    for (final item in items) {
      final date = OllamaSummarizer.formatDate(item.date);
      final title = item.title.trim().isEmpty ? '无标题' : item.title.trim();
      final text = item.summary.isEmpty ? '（无摘要）' : item.summary;
      buffer.writeln('- [$date-$title] $text');
    }
    if (attachments.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 附件')
        ..writeln();
      for (final name in attachments) {
        buffer.writeln('- $name');
      }
    }
    buffer
      ..writeln()
      ..writeln('## 关键点 / 待办')
      ..writeln()
      ..writeln('- （示范模型没有提炼能力）')
      ..writeln()
      ..writeln('## 一句话总结')
      ..writeln()
      ..writeln('这一天记了 ${items.length} 条记录。');
    return buffer.toString().trim();
  }
}
