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

/// 摘要生成器：默认本地 Ollama；测试用 [FakeSummarizer]。
abstract class Summarizer {
  String get modelId;

  Future<bool> isAvailable();

  Future<EntrySummary> summarize({
    required String title,
    required DateTime date,
    required String body,
    required List<String> tags,
  });
}

class SummarizerUnavailable implements Exception {
  SummarizerUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本地 Ollama 的对话接口（`/api/chat`，`format: json`）。
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/api/chat'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object>{
          'model': model,
          'stream': false,
          'format': 'json',
          'options': <String, Object>{'temperature': 0.2},
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
      final content = decoded is Map
          ? (decoded['message'] is Map
                ? '${(decoded['message'] as Map)['content'] ?? ''}'
                : '')
          : '';
      return parseSummary(content);
    } on SocketException catch (error) {
      throw SummarizerUnavailable(
        '连不上本地 Ollama（$baseUrl）：${error.message}。'
        '先安装 Ollama 并执行 `ollama pull $model`。',
      );
    } on HttpException catch (error) {
      throw SummarizerUnavailable('本地 Ollama 请求失败：${error.message}');
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
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return '你是一个日记整理助手。请阅读这篇日记，输出严格 JSON（不要输出其它内容）：\n'
        '{"summary": "1-2 句中文摘要，不超过 80 字，只概括事实", '
        '"tags": ["2-4 个短标签"]}\n\n'
        '日期：$dateText\n'
        '标题：${title.trim().isEmpty ? '（无标题）' : title.trim()}\n'
        '已有标签：${tags.isEmpty ? '（无）' : tags.join('、')}\n'
        '正文：\n$truncated';
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

  static String _short(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// 测试/离线用：按正文生成一句确定性摘要，不打网络。
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
}
