import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/rag/answer.dart';
import 'package:mdiary/rag/chat.dart';
import 'package:mdiary/rag/rag_service.dart';

/// 2.4：对话模式「先检索、再回答」——追问改写检索词、合并去重。
void main() {
  RagHit hit(String id, String label, double score) => RagHit(
    chunkId: id,
    kind: 'entry',
    label: label,
    text: '$label 的正文',
    snippet: '$label 的片段',
    date: DateTime(2026, 11, 1),
    score: score,
    entryId: 'e-$id',
  );

  test('首轮不调用改写，直接用原问题检索', () async {
    final answerer = _StubAnswerer();
    final chat = RagChat(
      search: (query, k) async => <RagHit>[hit('a', query, 0.9)],
      answerer: answerer,
    );
    final reply = await chat.ask(question: '西湖');
    expect(reply.queries, <String>['西湖']);
    expect(answerer.completeCalls, 0);
    expect(reply.sources, hasLength(1));
    expect(await reply.answer.join(), contains('回答：西湖'));
  });

  test('有上文时把追问改写成检索词，并合并去重', () async {
    final answerer = _StubAnswerer(
      completion: '{"queries":["杭州 西湖","杭州 天气"]}',
    );
    final requested = <String>[];
    final chat = RagChat(
      search: (query, k) async {
        requested.add(query);
        return <RagHit>[
          hit('same', '杭州西湖', 0.8),
          hit('only-$query', query, 0.6),
        ];
      },
      answerer: answerer,
    );
    final reply = await chat.ask(
      question: '那天气呢？',
      history: const <AnswerTurn>[
        AnswerTurn(question: '去年去哪了？', answer: '去杭州出差了。'),
      ],
    );
    expect(answerer.completeCalls, 1);
    expect(answerer.lastPrompt, contains('去年去哪了？'));
    expect(requested, <String>['杭州 西湖', '杭州 天气']);
    expect(reply.queries, <String>['杭州 西湖', '杭州 天气']);
    expect(
      reply.sources.where((h) => h.chunkId == 'same'),
      hasLength(1),
      reason: '同一片段只保留一条',
    );
    expect(reply.sources.first.score, 0.8, reason: '按最高分排序');
  });

  test('模型不返回 JSON 时退回原问题', () async {
    final answerer = _StubAnswerer(completion: '我觉得应该搜索杭州');
    final chat = RagChat(
      search: (query, k) async => <RagHit>[hit('a', query, 0.9)],
      answerer: answerer,
    );
    final reply = await chat.ask(
      question: '那天气呢？',
      history: const <AnswerTurn>[
        AnswerTurn(question: '去哪了？', answer: '杭州。'),
      ],
    );
    expect(reply.queries, <String>['那天气呢？']);
  });

  test('改写调用失败时退回原问题', () async {
    final answerer = _StubAnswerer(error: AnswererUnavailable('offline'));
    final chat = RagChat(
      search: (query, k) async => <RagHit>[hit('a', query, 0.9)],
      answerer: answerer,
    );
    final reply = await chat.ask(
      question: '那天气呢？',
      history: const <AnswerTurn>[
        AnswerTurn(question: '去哪了？', answer: '杭州。'),
      ],
    );
    expect(reply.queries, <String>['那天气呢？']);
  });

  test('提示词要求只输出 JSON 且带上下文', () {
    final prompt = RagChat.buildPlannerPrompt(
      question: '那天气呢？',
      history: const <AnswerTurn>[
        AnswerTurn(question: '去年去哪了？', answer: '去杭州出差了。'),
      ],
    );
    expect(prompt, contains('JSON'));
    expect(prompt, contains('去年去哪了？'));
    expect(prompt, contains('那天气呢？'));
  });
}

class _StubAnswerer implements Answerer {
  _StubAnswerer({this.completion = '{"queries":["杭州"]}', this.error});

  final String completion;
  final Object? error;
  int completeCalls = 0;
  String lastPrompt = '';

  @override
  String get modelId => 'stub';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> complete(String prompt) async {
    completeCalls++;
    lastPrompt = prompt;
    if (error != null) throw error!;
    return completion;
  }

  @override
  Stream<String> streamAnswer({
    required String question,
    required List<AnswerSource> sources,
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) async* {
    yield '回答：$question（${sources.length} 条来源）';
  }
}
