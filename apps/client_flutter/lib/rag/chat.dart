import 'dart:convert';

import 'answer.dart';
import 'rag_service.dart';

/// 一次对话请求：先由模型改写成检索词，再混合检索，最后生成带引用的回答。
class ChatReply {
  const ChatReply({
    required this.sources,
    required this.answer,
    required this.queries,
  });

  final List<RagHit> sources;
  final List<String> queries;
  final Stream<String> answer;
}

/// RAG 对话：**模型先检索、再回答**。
///
/// 首轮直接用问题检索；有上文时先用交互模型把追问改写成 1–3 条独立检索词，
/// 合并去重后再交给 [Answerer] 生成（带 [日期-标题] 引用）。
class RagChat {
  RagChat({
    required this.search,
    required this.answerer,
    this.maxQueries = 3,
    this.topK = 8,
  });

  final Future<List<RagHit>> Function(String query, int k) search;
  final Answerer answerer;
  final int maxQueries;
  final int topK;

  Future<ChatReply> ask({
    required String question,
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) async {
    final queries = await planQueries(question, history);
    final hits = await _searchAll(queries);
    final sources = <AnswerSource>[
      for (final hit in hits)
        AnswerSource(
          label: hit.label,
          date: hit.date,
          text: hit.text,
          kind: hit.kind,
        ),
    ];
    return ChatReply(
      sources: hits,
      queries: queries,
      answer: answerer.streamAnswer(
        question: question,
        sources: sources,
        history: history,
      ),
    );
  }

  /// 有上文时让模型把追问改写成独立检索词；失败就退回原问题。
  Future<List<String>> planQueries(
    String question,
    List<AnswerTurn> history,
  ) async {
    if (history.isEmpty) return <String>[question];
    try {
      final raw = await answerer.complete(
        buildPlannerPrompt(question: question, history: history),
      );
      final text = _stripFence(raw);
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final list = decoded['queries'];
        if (list is List) {
          final queries = <String>[];
          for (final item in list) {
            final query = '$item'.trim();
            if (query.isNotEmpty) queries.add(query);
            if (queries.length >= maxQueries) break;
          }
          if (queries.isNotEmpty) return queries;
        }
      }
    } on Object {
      // 模型不听话 / 不是 JSON：直接用原问题
    }
    return <String>[question];
  }

  static String buildPlannerPrompt({
    required String question,
    required List<AnswerTurn> history,
  }) {
    final buffer = StringBuffer()
      ..writeln('你在帮一个日记检索系统把追问改写成检索词。')
      ..writeln('根据下面的对话，把用户最后一句话改写成 1–3 条**不依赖上下文**的检索词，')
      ..writeln('要包含可能是线索的人名、地点、时间、事件；不要回答问题。')
      ..writeln('只输出 JSON：{"queries":["...","..."]}')
      ..writeln();
    for (final turn in history.reversed.take(3).toList().reversed) {
      final answer = turn.answer.trim();
      buffer
        ..writeln('问：${turn.question.trim()}')
        ..writeln(
          '答：${answer.length <= 120 ? answer : '${answer.substring(0, 120)}…'}',
        );
    }
    buffer
      ..writeln()
      ..writeln('用户：${question.trim()}');
    return buffer.toString();
  }

  Future<List<RagHit>> _searchAll(List<String> queries) async {
    final merged = <String, RagHit>{};
    for (final query in queries) {
      final hits = await search(query, topK);
      for (final hit in hits) {
        final existing = merged[hit.chunkId];
        if (existing == null || hit.score > existing.score) {
          merged[hit.chunkId] = hit;
        }
      }
    }
    final list = merged.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return list.take(topK).toList();
  }

  static String _stripFence(String content) {
    var text = content.trim();
    if (text.startsWith('```')) {
      final newline = text.indexOf('\n');
      if (newline >= 0) text = text.substring(newline + 1);
      if (text.endsWith('```')) text = text.substring(0, text.length - 3);
    }
    return text.trim();
  }
}
