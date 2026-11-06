import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'answer.dart';
import 'summarizer.dart';

/// 云端（OpenAI 兼容）模型配置。
class CloudConfig {
  const CloudConfig({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  /// 去掉末尾斜杠，拼出 `/chat/completions`。
  Uri get chatUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  Uri get modelsUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/models');
  }

  Map<String, String> get headers => <String, String>{
    'Authorization': 'Bearer $apiKey',
  };
}

class CloudUnavailable implements Exception {
  CloudUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 云端流式问答（OpenAI `chat/completions`，`stream: true`）。
class CloudAnswerer implements Answerer {
  CloudAnswerer(this.config);

  final CloudConfig config;

  @override
  String get modelId => 'cloud:${config.model}';

  @override
  Future<bool> isAvailable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(config.modelsUri);
      config.headers.forEach(request.headers.set);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<String> streamAnswer({
    required String question,
    required List<AnswerSource> sources,
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) async* {
    if (sources.isEmpty) {
      yield '没有在日记里找到相关内容。';
      return;
    }
    final prompt = OllamaAnswerer.buildPrompt(
      question: question,
      sources: sources,
      history: history,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(config.chatUri);
      config.headers.forEach(request.headers.set);
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.write(
        jsonEncode(<String, Object>{
          'model': config.model,
          'stream': true,
          'temperature': 0.3,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': prompt},
          ],
        }),
      );
      final response = await request.close().timeout(
        const Duration(minutes: 3),
      );
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw CloudUnavailable(_httpError(response.statusCode, body));
      }
      final lines = response
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        final text = line.trim();
        if (!text.startsWith('data:')) continue;
        final payload = text.substring(5).trim();
        if (payload == '[DONE]') break;
        Map<String, dynamic>? chunk;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) chunk = decoded;
        } on FormatException {
          continue;
        }
        final choices = chunk?['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final delta = choices.first is Map ? (choices.first as Map)['delta'] : null;
        if (delta is Map) {
          final content = '${delta['content'] ?? ''}';
          if (content.isNotEmpty) yield content;
        }
      }
    } on SocketException catch (error) {
      throw CloudUnavailable('连不上云端服务：${error.message}');
    } on HttpException catch (error) {
      throw CloudUnavailable('云端请求失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static String _httpError(int status, String body) {
    final short = body.length <= 200 ? body : '${body.substring(0, 200)}…';
    if (status == 401 || status == 403) {
      return 'API Key 无效或没有权限（$status）：$short';
    }
    if (status == 404) {
      return '地址或模型不对（404）：$short';
    }
    if (status == 429) {
      return '请求太频繁或额度用完了（429）：$short';
    }
    return '云端返回 $status：$short';
  }
}

/// 云端摘要 / 日报 / soul.md（OpenAI 兼容，非流式）。
class CloudSummarizer implements Summarizer {
  CloudSummarizer(this.config);

  final CloudConfig config;

  @override
  String get modelId => 'cloud:${config.model}';

  @override
  Future<bool> isAvailable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(config.modelsUri);
      config.headers.forEach(request.headers.set);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
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
    final prompt = OllamaSummarizer.buildPrompt(
      title: title,
      date: date,
      body: body,
      tags: tags,
    );
    final content = await _complete(prompt, jsonMode: true);
    return OllamaSummarizer.parseSummary(content);
  }

  @override
  Future<String> generateReport({
    required DateTime date,
    required List<ReportInput> items,
    required List<String> attachments,
  }) async {
    final prompt = OllamaSummarizer.buildReportPrompt(
      date: date,
      items: items,
      attachments: attachments,
    );
    final content = await _complete(prompt, jsonMode: false);
    final text = OllamaSummarizer.stripFence(content);
    if (text.isEmpty) throw CloudUnavailable('云端返回了空日报');
    return text;
  }

  @override
  Future<SoulSections> generateSoul({required String digest}) async {
    final prompt = OllamaSummarizer.buildSoulPrompt(digest);
    final content = await _complete(prompt, jsonMode: true);
    final decoded = OllamaSummarizer.parseJsonObject(content);
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

  Future<String> _complete(String prompt, {required bool jsonMode}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(config.chatUri);
      config.headers.forEach(request.headers.set);
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.write(
        jsonEncode(<String, Object>{
          'model': config.model,
          'stream': false,
          'temperature': 0.3,
          if (jsonMode) 'response_format': <String, String>{'type': 'json_object'},
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': prompt},
          ],
        }),
      );
      final response = await request.close().timeout(
        const Duration(minutes: 3),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw CloudUnavailable(CloudAnswerer._httpError(response.statusCode, body));
      }
      final decoded = jsonDecode(body);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is! List || choices.isEmpty) {
        throw CloudUnavailable('云端响应里没有 choices');
      }
      final message = choices.first is Map
          ? (choices.first as Map)['message']
          : null;
      final content = message is Map ? '${message['content'] ?? ''}' : '';
      if (content.trim().isEmpty) throw CloudUnavailable('云端返回了空内容');
      return content;
    } on SocketException catch (error) {
      throw CloudUnavailable('连不上云端服务：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}

/// 通用的云端文本补全（蒸馏 skill 用）：一次请求、返回纯文本。
class CloudCompleter {
  CloudCompleter(this.config, {this.temperature = 0.4, this.timeout = const Duration(minutes: 5)});

  final CloudConfig config;
  final double temperature;
  final Duration timeout;

  String get modelId => 'cloud:${config.model}';

  Future<bool> isAvailable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(config.modelsUri);
      config.headers.forEach(request.headers.set);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> complete(String prompt, {int maxTokens = 1500}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(config.chatUri);
      config.headers.forEach(request.headers.set);
      request.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      request.write(
        jsonEncode(<String, Object>{
          'model': config.model,
          'stream': false,
          'temperature': temperature,
          'max_tokens': maxTokens,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': prompt},
          ],
        }),
      );
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw CloudUnavailable(CloudAnswerer._httpError(response.statusCode, body));
      }
      final decoded = jsonDecode(body);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is! List || choices.isEmpty) {
        throw CloudUnavailable('云端响应里没有 choices');
      }
      final message = choices.first is Map
          ? (choices.first as Map)['message']
          : null;
      final content = message is Map ? '${message['content'] ?? ''}' : '';
      if (content.trim().isEmpty) throw CloudUnavailable('云端返回了空内容');
      return content;
    } on SocketException catch (error) {
      throw CloudUnavailable('连不上云端服务：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}