import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 文本向量化。
///
/// 默认走本地 Ollama（`/api/embed`）；[HashingEmbedder] 只用于离线自检与单元测试。
abstract class Embedder {
  /// 写进索引元数据的模型标识；变了就整库重建。
  String get modelId;

  /// 向量维度；第一次调用 [embed] 之前可能未知（Ollama 由响应决定）。
  int? get dimension;

  Future<List<List<double>>> embed(List<String> texts);
}

/// 本地模型不可用（没装 Ollama、模型没拉、连接失败）。
class EmbedderUnavailable implements Exception {
  EmbedderUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本地 Ollama 的 embedding 接口。
class OllamaEmbedder implements Embedder {
  OllamaEmbedder({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model = 'bge-m3',
    this.timeout = const Duration(minutes: 2),
  });

  final String baseUrl;
  final String model;
  final Duration timeout;

  int? _dimension;

  @override
  String get modelId => 'ollama:$model';

  @override
  int? get dimension => _dimension;

  /// 探测 Ollama 是否在线、模型是否存在。
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
  Future<List<List<double>>> embed(List<String> texts) async {
    if (texts.isEmpty) return const <List<double>>[];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('$baseUrl/api/embed'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(<String, Object>{'model': model, 'input': texts}));
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw EmbedderUnavailable(
          'Ollama 返回 ${response.statusCode}：${_short(body)}（模型 $model 是否已拉取？）',
        );
      }
      final decoded = jsonDecode(body);
      final raw = decoded is Map ? decoded['embeddings'] : null;
      if (raw is! List || raw.length != texts.length) {
        throw EmbedderUnavailable('Ollama 响应异常：embeddings 数量不匹配');
      }
      final result = <List<double>>[];
      for (final item in raw) {
        if (item is! List || item.isEmpty) {
          throw EmbedderUnavailable('Ollama 返回了空向量');
        }
        result.add(normalize(item.map((v) => (v as num).toDouble()).toList()));
      }
      _dimension = result.first.length;
      return result;
    } on SocketException catch (error) {
      throw EmbedderUnavailable(
        '连不上本地 Ollama（$baseUrl）：${error.message}。'
        '先安装 Ollama 并执行 `ollama pull $model`。',
      );
    } on HttpException catch (error) {
      throw EmbedderUnavailable('本地 Ollama 请求失败：${error.message}');
    } on FormatException {
      throw EmbedderUnavailable('Ollama 响应不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }

  static String _short(String text) =>
      text.length <= 160 ? text : '${text.substring(0, 160)}…';
}

/// 确定性哈希向量：离线自检/测试用，不联网、不需要模型。
///
/// 语义质量远不如真模型，只保证「同样文本 → 同样向量」。
class HashingEmbedder implements Embedder {
  HashingEmbedder({this.dimension = 256, this.model = 'hash'});

  @override
  final int dimension;
  final String model;

  @override
  String get modelId => '$model:$dimension';

  @override
  Future<List<List<double>>> embed(List<String> texts) async =>
      texts.map(_embedOne).toList(growable: false);

  List<double> _embedOne(String text) {
    final vector = List<double>.filled(dimension, 0);
    final lower = text.toLowerCase();
    for (var i = 0; i + 1 < lower.length; i++) {
      final bigram = lower.substring(i, i + 2);
      final bucket = _fnv1a(bigram) % dimension;
      vector[bucket] += 1;
    }
    for (final word in lower.split(RegExp(r'\s+'))) {
      if (word.length < 2) continue;
      vector[_fnv1a(word) % dimension] += 0.5;
    }
    return normalize(vector);
  }

  static int _fnv1a(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}

/// L2 归一化：检索用余弦相似度，归一化后点积就是余弦。
List<double> normalize(List<double> vector) {
  var sum = 0.0;
  for (final value in vector) {
    sum += value * value;
  }
  if (sum == 0) return vector;
  final norm = math.sqrt(sum);
  return <double>[for (final value in vector) value / norm];
}
