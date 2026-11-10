import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 问答引用的一条来源。
class AnswerSource {
  const AnswerSource({
    required this.label,
    required this.date,
    required this.text,
    required this.kind,
  });

  final String label;
  final DateTime date;
  final String text;

  /// `entry` 或 `attachment`。
  final String kind;

  String get citation =>
      '[${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}-$label]';
}

class AnswererUnavailable implements Exception {
  AnswererUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一轮已完成的问答（多轮追问用）。
class AnswerTurn {
  const AnswerTurn({required this.question, required this.answer});

  final String question;
  final String answer;
}

/// 问答生成器（流式）。默认本地 Ollama；测试用 [FakeAnswerer]。
abstract class Answerer {
  String get modelId;

  Future<bool> isAvailable();

  Stream<String> streamAnswer({
    required String question,
    required List<AnswerSource> sources,
    List<AnswerTurn> history = const <AnswerTurn>[],
  });

  /// 非流式补全：用于把追问改写成检索词（对话模式）。
  Future<String> complete(String prompt);
}

/// 本地 Ollama 的流式问答。
class OllamaAnswerer implements Answerer {
  OllamaAnswerer({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model = 'qwen3:8b',
    this.timeout = const Duration(minutes: 5),
    this.maxSourceChars = 900,
    this.temperature = 0.3,
    this.numCtx = 0,
  });

  final String baseUrl;
  final String model;
  final Duration timeout;
  final int maxSourceChars;
  final double temperature;
  final int numCtx;

  @override
  String get modelId => 'ollama:$model';

  @override
  Future<bool> isAvailable() async => (await listOllamaModels(baseUrl: baseUrl))
      .any((name) => name == model || name.startsWith('$model:'));

  @override
  Stream<String> streamAnswer({
    required String question,
    required List<AnswerSource> sources,
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) async* {
    if (sources.isEmpty) {
      yield '没有在日记里找到相关内容。换个说法，或先点右上角「重建索引」。';
      return;
    }
    final prompt = buildPrompt(
      question: question,
      sources: sources,
      maxSourceChars: maxSourceChars,
      history: history,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      HttpClientResponse? response;
      for (final think in <bool>[false, true]) {
        final request = await client.postUrl(Uri.parse('$baseUrl/api/chat'));
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode(<String, Object>{
            'model': model,
            'stream': true,
            // qwen3 这类思考模型默认会先"想"很久，问答场景关掉更好：
            // 实测 27.5s / 答错 → 9s / 答对。
            if (!think) 'think': false,
            'options': <String, Object>{
              'temperature': temperature,
              'num_predict': 320,
              if (numCtx > 0) 'num_ctx': numCtx,
            },
            'messages': <Map<String, String>>[
              <String, String>{'role': 'user', 'content': prompt},
            ],
          }),
        );
        response = await request.close().timeout(timeout);
        if (response.statusCode == 200) break;
        final body = await response.transform(utf8.decoder).join();
        // 老版本 Ollama 不认 think：去掉它再试一次
        if (think && body.contains('think')) {
          throw AnswererUnavailable(
            'Ollama 返回 ${response.statusCode}：${_short(body)}',
          );
        }
      }
      if (response == null || response.statusCode != 200) {
        throw AnswererUnavailable(
          'Ollama 返回 ${response?.statusCode}：模型 $model 是否已拉取？',
        );
      }
      final lines = response
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        Map<String, dynamic>? chunk;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) chunk = decoded;
        } on FormatException {
          continue;
        }
        if (chunk == null) continue;
        final message = chunk['message'];
        if (message is Map) {
          final text = '${message['content'] ?? ''}';
          if (text.isNotEmpty) yield text;
        }
        if (chunk['done'] == true) break;
      }
    } on SocketException catch (error) {
      throw AnswererUnavailable(
        '连不上本地 Ollama（$baseUrl）：${error.message}。',
      );
    } on HttpException catch (error) {
      throw AnswererUnavailable('本地 Ollama 请求失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String> complete(String prompt) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      for (final withThink in <bool>[false, true]) {
        final request = await client.postUrl(Uri.parse('$baseUrl/api/chat'));
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode(<String, Object>{
            'model': model,
            'stream': false,
            if (!withThink) 'think': false,
            'options': <String, Object>{'temperature': 0.2, 'num_predict': 160},
            'messages': <Map<String, String>>[
              <String, String>{'role': 'user', 'content': prompt},
            ],
          }),
        );
        final response = await request.close().timeout(timeout);
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final decoded = jsonDecode(body);
          if (decoded is Map) {
            final message = decoded['message'];
            if (message is Map) return '${message['content'] ?? ''}';
          }
          return '';
        }
      }
      throw AnswererUnavailable('Ollama 返回错误：模型 $model 是否已拉取？');
    } on SocketException catch (error) {
      throw AnswererUnavailable(
        '连不上本地 Ollama（$baseUrl）：${error.message}。',
      );
    } finally {
      client.close(force: true);
    }
  }

  static String buildPrompt({
    required String question,
    required List<AnswerSource> sources,
    int maxSourceChars = 900,
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) {
    final buffer = StringBuffer()
      ..writeln('你是一个日记助手。只根据下面的日记片段回答问题，不要编造。')
      ..writeln('每条事实后面用方括号标注来源，格式：[日期-标题]；没有依据就说「日记里没有提到」。')
      ..writeln('用中文回答，控制在 200 字以内。');
    if (history.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('之前的对话（可以结合上下文，但事实仍只能来自片段）：');
      for (final turn in history.take(3)) {
        final answer = turn.answer.trim();
        buffer
          ..writeln('问：${turn.question.trim()}')
          ..writeln(
            '答：${answer.length <= 200 ? answer : '${answer.substring(0, 200)}…'}',
          );
      }
    }
    buffer
      ..writeln()
      ..writeln('问题：$question')
      ..writeln()
      ..writeln('日记片段：');
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final text = source.text.length <= maxSourceChars
          ? source.text
          : '${source.text.substring(0, maxSourceChars)}…';
      buffer
        ..writeln('--- 片段 ${i + 1} ${source.citation} ---')
        ..writeln(text)
        ..writeln();
    }
    return buffer.toString();
  }

  static String _short(String text) =>
      text.length <= 160 ? text : '${text.substring(0, 160)}…';
}

/// 测试 / 离线：立刻给出确定性答案。
class FakeAnswerer implements Answerer {
  FakeAnswerer({this.model = 'fake-answer'});

  final String model;

  @override
  String get modelId => 'fake:$model';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> complete(String prompt) async => '{"queries":["杭州"]}';

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
    if (history.isNotEmpty) yield '（继续）';
    yield '根据记录，';
    for (final source in sources.take(3)) {
      yield '${source.citation} 提到「${source.text.characters}」；'.replaceAll(
        'Characters(…)',
        '',
      );
    }
    yield '以上是示范回答。';
  }
}

extension on String {
  String get characters {
    final flat = replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 24 ? flat : '${flat.substring(0, 24)}…';
  }
}

/// 列出本机 Ollama 已安装的模型名；失败返回空列表。
Future<List<String>> listOllamaModels({String baseUrl = 'http://127.0.0.1:11434'}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(Uri.parse('$baseUrl/api/tags'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) return const <String>[];
    final decoded = jsonDecode(body);
    final models = decoded is Map ? decoded['models'] : null;
    if (models is! List) return const <String>[];
    return models
        .whereType<Map>()
        .map((item) => '${item['name'] ?? ''}'.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  } on Object {
    return const <String>[];
  } finally {
    client.close(force: true);
  }
}
