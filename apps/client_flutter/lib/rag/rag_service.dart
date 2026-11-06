import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/attachment_repository.dart';
import '../data/attachment_store.dart';
import '../data/entry_repository.dart';
import '../data/tag_repository.dart';
import 'chunker.dart';
import 'embedder.dart';
import 'rag_database.dart';
import 'semantic_indexer.dart';

class RagHit {
  const RagHit({
    required this.chunkId,
    required this.kind,
    required this.label,
    required this.text,
    required this.snippet,
    required this.date,
    required this.score,
    this.entryId,
    this.attachmentId,
  });

  final String chunkId;
  final String kind;
  final String label;
  final String text;
  final String snippet;
  final DateTime date;
  final double score;
  final String? entryId;
  final String? attachmentId;

  bool get isAttachment => kind == 'attachment';

  Map<String, Object?> toJson() => <String, Object?>{
    'chunkId': chunkId,
    'kind': kind,
    'label': label,
    'date': ChunkerDate.format(date),
    'score': double.parse(score.toStringAsFixed(4)),
    'entryId': entryId,
    'attachmentId': attachmentId,
    'snippet': snippet,
    'text': text,
  };
}

class RagStats {
  const RagStats({
    required this.chunks,
    required this.entries,
    required this.attachments,
    required this.model,
    required this.dimension,
    required this.indexedAt,
  });

  final int chunks;
  final int entries;
  final int attachments;
  final String model;
  final int dimension;
  final String indexedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'chunks': chunks,
    'entries': entries,
    'attachments': attachments,
    'model': model,
    'dimension': dimension,
    'indexedAt': indexedAt,
  };
}

/// v2.0 RAG 入口：`<库目录>/rag/index.sqlite` + 增量索引 + 混合检索。
class RagService {
  RagService({
    required this.libraryRoot,
    required this.database,
    required this.indexer,
    required this.embedder,
  });

  final String libraryRoot;
  final RagDatabase database;
  final SemanticIndexer indexer;
  final Embedder embedder;

  static const String directoryName = 'rag';

  static String directoryFor(String libraryRoot) =>
      p.join(libraryRoot, directoryName);

  static String indexPathFor(String libraryRoot) =>
      p.join(directoryFor(libraryRoot), 'index.sqlite');

  static RagService open({
    required String libraryRoot,
    required EntryRepository entries,
    required AttachmentRepository attachments,
    required TagRepository tags,
    required AttachmentStore store,
    Embedder? embedder,
    MarkdownChunker? chunker,
  }) {
    final database = RagDatabase.open(indexPathFor(libraryRoot));
    final effectiveEmbedder = embedder ?? OllamaEmbedder();
    return RagService(
      libraryRoot: libraryRoot,
      database: database,
      embedder: effectiveEmbedder,
      indexer: SemanticIndexer(
        rag: database,
        entries: entries,
        attachments: attachments,
        tags: tags,
        store: store,
        embedder: effectiveEmbedder,
        chunker: chunker,
      ),
    );
  }

  Future<IndexReport> reindex({
    bool force = false,
    void Function(IndexProgress progress)? onProgress,
  }) => indexer.run(force: force, onProgress: onProgress);

  RagStats stats() {
    final chunks = database.chunkCount();
    final model = database.meta('embed_model') ?? '';
    final dimension = int.tryParse(database.meta('embed_dim') ?? '') ?? 0;
    final indexedAt = database.meta('indexed_at') ?? '';
    final entries =
        database.raw
            .select('SELECT COUNT(*) AS c FROM entry_index')
            .first['c']
        as int;
    final attachments =
        database.raw
            .select('SELECT COUNT(*) AS c FROM attachment_index')
            .first['c']
        as int;
    return RagStats(
      chunks: chunks,
      entries: entries,
      attachments: attachments,
      model: model,
      dimension: dimension,
      indexedAt: indexedAt,
    );
  }

  /// 混合检索：向量余弦 + 关键词命中，用 RRF 融合。
  Future<List<RagHit>> search(String query, {int k = 8}) async {
    final text = query.trim();
    if (text.isEmpty) return const <RagHit>[];
    final chunks = database.chunksWithVectors();
    if (chunks.isEmpty) return const <RagHit>[];

    List<double>? queryVector;
    try {
      queryVector = (await embedder.embed(<String>[text])).first;
    } on EmbedderUnavailable {
      queryVector = null; // 模型不可用时退化为关键词检索
    }

    final scores = <String, double>{};
    final byVector = <_Scored>[];
    final byKeyword = <_Scored>[];

    for (final chunk in chunks) {
      var cosine = 0.0;
      if (queryVector != null && queryVector.length == chunk.vector.length) {
        cosine = _dot(chunk.vector, queryVector);
      }
      final keyword = _keywordScore(chunk, text);
      final scored = _Scored(chunk, cosine, keyword);
      if (queryVector != null) byVector.add(scored);
      if (keyword > 0) byKeyword.add(scored);
    }

    byVector.sort((a, b) => b.cosine.compareTo(a.cosine));
    byKeyword.sort((a, b) => b.keyword.compareTo(a.keyword));

    const rrfK = 60.0;
    for (var i = 0; i < byVector.length; i++) {
      scores[byVector[i].chunk.id] =
          (scores[byVector[i].chunk.id] ?? 0) + 1 / (rrfK + i + 1);
    }
    for (var i = 0; i < byKeyword.length; i++) {
      scores[byKeyword[i].chunk.id] =
          (scores[byKeyword[i].chunk.id] ?? 0) + 1 / (rrfK + i + 1);
    }

    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final byId = <String, ChunkWithVector>{
      for (final chunk in chunks) chunk.id: chunk,
    };

    final hits = <RagHit>[];
    for (final item in ranked.take(k)) {
      final chunk = byId[item.key];
      if (chunk == null) continue;
      hits.add(
        RagHit(
          chunkId: chunk.id,
          kind: chunk.kind,
          label: chunk.label,
          text: chunk.text,
          snippet: _snippet(chunk.text, text),
          date: chunk.sourceDate,
          score: item.value,
          entryId: chunk.entryId,
          attachmentId: chunk.attachmentId,
        ),
      );
    }
    return hits;
  }

  void close() => database.close();

  static double _dot(List<double> a, List<double> b) {
    var sum = 0.0;
    final length = math.min(a.length, b.length);
    for (var i = 0; i < length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  static int _keywordScore(ChunkWithVector chunk, String query) {
    final needle = query.toLowerCase();
    var score = 0;
    final haystack = chunk.text.toLowerCase();
    var index = haystack.indexOf(needle);
    while (index >= 0) {
      score += 1;
      index = haystack.indexOf(needle, index + needle.length);
    }
    if (chunk.label.toLowerCase().contains(needle)) score += 3;
    if (chunk.headingPath.toLowerCase().contains(needle)) score += 2;
    return score;
  }

  static String _snippet(String text, String query) {
    final body = text
        .split('\n')
        .where(
          (line) =>
              !line.startsWith('《') &&
              !line.startsWith('章节：') &&
              !line.startsWith('附件：') &&
              !line.startsWith('类型：') &&
              !line.startsWith('所属日记：'),
        )
        .join('\n')
        .trim();
    final source = body.isEmpty ? text : body;
    final flat = source.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 180) return flat;

    final index = flat.toLowerCase().indexOf(query.toLowerCase());
    if (index <= 0) return '${flat.substring(0, 180)}…';
    final start = math.max(0, index - 70);
    final end = math.min(flat.length, start + 180);
    return '${start > 0 ? '…' : ''}'
        '${flat.substring(start, end)}'
        '${end < flat.length ? '…' : ''}';
  }
}

class _Scored {
  _Scored(this.chunk, this.cosine, this.keyword);

  final ChunkWithVector chunk;
  final double cosine;
  final int keyword;
}

/// 少量日期格式化工具，避免 rag 层依赖 UI 层。
class ChunkerDate {
  static String format(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
