import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/attachment_repository.dart';
import '../data/attachment_store.dart';
import '../data/entry_repository.dart';
import '../data/models.dart';
import '../data/tag_repository.dart';
import 'attachment_text.dart';
import 'chunker.dart';
import 'embedder.dart';
import 'rag_database.dart';

class IndexProgress {
  const IndexProgress({
    required this.done,
    required this.total,
    required this.label,
  });

  final int done;
  final int total;
  final String label;
}

class IndexReport {
  const IndexReport({
    required this.entriesIndexed,
    required this.entriesSkipped,
    required this.attachmentsIndexed,
    required this.attachmentsSkipped,
    required this.chunksWritten,
    required this.errors,
    required this.rebuilt,
    required this.model,
    required this.dimension,
  });

  final int entriesIndexed;
  final int entriesSkipped;
  final int attachmentsIndexed;
  final int attachmentsSkipped;
  final int chunksWritten;
  final List<String> errors;
  final bool rebuilt;
  final String model;
  final int dimension;

  @override
  String toString() =>
      '索引完成：日记 $entriesIndexed 篇（跳过 $entriesSkipped）、'
      '附件 $attachmentsIndexed 个（跳过 $attachmentsSkipped）、'
      '切片 $chunksWritten 条${rebuilt ? '，已因模型变化重建' : ''}'
      '${errors.isEmpty ? '' : '，失败 ${errors.length} 条'}';
}

/// 把日记与附件写进 RAG 索引（增量：内容没变就跳过）。
class SemanticIndexer {
  SemanticIndexer({
    required this.rag,
    required this.entries,
    required this.attachments,
    required this.tags,
    required this.store,
    required this.embedder,
    MarkdownChunker? chunker,
  }) : chunker = chunker ?? MarkdownChunker();

  final RagDatabase rag;
  final EntryRepository entries;
  final AttachmentRepository attachments;
  final TagRepository tags;
  final AttachmentStore store;
  final Embedder embedder;
  final MarkdownChunker chunker;

  Future<IndexReport> run({
    bool force = false,
    void Function(IndexProgress progress)? onProgress,
  }) async {
    final modelId = embedder.modelId;
    final previousModel = rag.meta('embed_model');
    final previousDim = int.tryParse(rag.meta('embed_dim') ?? '');
    var rebuilt = false;

    // 换了模型（或维度对不上）→ 旧向量全部作废，整库重建。
    if (previousModel != null && previousModel != modelId) {
      rag.clearIndex();
      rebuilt = true;
    }

    rag.setMeta('embed_model', modelId);

    final entryList = entries.query();
    final attachmentList = attachments.all();
    final total = entryList.length + attachmentList.length;
    var processed = 0;

    var entriesIndexed = 0;
    var entriesSkipped = 0;
    var attachmentsIndexed = 0;
    var attachmentsSkipped = 0;
    var chunksWritten = 0;
    var dimension = previousDim ?? 0;
    final errors = <String>[];

    for (final entry in entryList) {
      processed++;
      onProgress?.call(
        IndexProgress(
          done: processed,
          total: total,
          label: entry.title.trim().isEmpty ? '无标题' : entry.title,
        ),
      );
      try {
        final entryTags = tags.tagsOf(entry.id);
        final hash = _entryHash(entry, entryTags);
        if (!force && rag.entryHash(entry.id) == hash) {
          entriesSkipped++;
          continue;
        }
        final chunks = chunker.chunkEntry(
          entryId: entry.id,
          title: entry.title,
          date: entry.entryDate,
          body: entry.bodyMd,
          tags: entryTags,
        );
        final vectors = await embedder.embed(<String>[
          for (final chunk in chunks) chunk.text,
        ]);
        dimension = vectors.first.length;
        rag.deleteChunksForEntry(entry.id);
        rag.insertChunks(chunks, vectors);
        rag.setEntryHash(entry.id, hash, chunks.length);
        entriesIndexed++;
        chunksWritten += chunks.length;
      } on EmbedderUnavailable {
        rethrow;
      } on Object catch (error) {
        errors.add('《${entry.title}》：$error');
      }
    }

    for (final attachment in attachmentList) {
      processed++;
      onProgress?.call(
        IndexProgress(
          done: processed,
          total: total,
          label: attachment.filename,
        ),
      );
      try {
        final entry = entries.findById(attachment.entryId);
        if (entry == null) continue;
        final extension = normalizeExtension(attachment.filename);
        final path = store.pathFor(attachment.sha256, extension);
        final text = path == null ? null : await extractAttachmentText(path);
        final hash = _attachmentHash(attachment, text);
        if (!force && rag.attachmentHash(attachment.sha256) == hash) {
          attachmentsSkipped++;
          continue;
        }
        final chunks = chunker.chunkAttachment(
          attachmentId: attachment.id,
          entryId: entry.id,
          filename: attachment.filename,
          mime: attachment.mime,
          sizeBytes: attachment.sizeBytes,
          entryTitle: entry.title,
          date: entry.entryDate,
          extractedText: text,
        );
        final vectors = await embedder.embed(<String>[
          for (final chunk in chunks) chunk.text,
        ]);
        dimension = vectors.first.length;
        rag.deleteChunksForAttachment(attachment.id);
        rag.insertChunks(chunks, vectors);
        rag.setAttachmentHash(attachment.sha256, hash, chunks.length);
        if (text != null && text.trim().isNotEmpty) {
          rag.setAttachmentText(attachment.sha256, text, 'plain');
        }
        attachmentsIndexed++;
        chunksWritten += chunks.length;
      } on EmbedderUnavailable {
        rethrow;
      } on Object catch (error) {
        errors.add('附件 ${attachment.filename}：$error');
      }
    }

    if (dimension > 0) rag.setMeta('embed_dim', '$dimension');
    rag.setMeta('indexed_at', DateTime.now().toIso8601String());

    return IndexReport(
      entriesIndexed: entriesIndexed,
      entriesSkipped: entriesSkipped,
      attachmentsIndexed: attachmentsIndexed,
      attachmentsSkipped: attachmentsSkipped,
      chunksWritten: chunksWritten,
      errors: errors,
      rebuilt: rebuilt,
      model: modelId,
      dimension: dimension,
    );
  }

  static String _entryHash(Entry entry, List<String> entryTags) {
    final payload = <String>[
      entry.title,
      entry.bodyMd,
      entry.entryDate.toIso8601String(),
      entryTags.join(','),
    ].join('\n');
    return sha256.convert(utf8.encode(payload)).toString();
  }

  static String _attachmentHash(Attachment attachment, String? text) {
    final payload = <String>[
      attachment.filename,
      attachment.mime,
      '${attachment.sizeBytes}',
      text ?? '',
    ].join('\n');
    return sha256.convert(utf8.encode(payload)).toString();
  }
}
