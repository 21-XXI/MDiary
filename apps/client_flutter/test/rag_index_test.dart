@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/embedder.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 2.0.1：RAG 索引（切片、附件索引、增量、检索、换模型重建）。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  late Directory sandbox;
  late Directory libraryRoot;
  late AppDatabase db;
  late EntryRepository entries;
  late AttachmentRepository attachments;
  late TagRepository tags;
  late AttachmentStore store;
  RagService? service;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_rag_');
    libraryRoot = Directory(p.join(sandbox.path, 'lib'))..createSync();
    Directory(p.join(libraryRoot.path, 'db')).createSync(recursive: true);
    db = AppDatabase.open(p.join(libraryRoot.path, 'db', 'mdiary.sqlite'));
    entries = EntryRepository(db);
    attachments = AttachmentRepository(db);
    tags = TagRepository(db);
    store = AttachmentStore(
      Directory(p.join(libraryRoot.path, 'attachments')),
      blobs: attachments,
    );
  });

  tearDown(() {
    service?.close();
    service = null;
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  RagService openWith(HashingEmbedder embedder) {
    service?.close();
    service = RagService.open(
      libraryRoot: libraryRoot.path,
      entries: entries,
      attachments: attachments,
      tags: tags,
      store: store,
      embedder: embedder,
    );
    return service!;
  }

  test('建索引：日记与附件都进库，再跑一次全部跳过', () async {
    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 5),
      title: '杭州出差',
      body: '# 第一天\n\n去了西湖，风很大。',
    );
    tags.setTags(entry.id, <String>['旅行']);

    final svc = openWith(HashingEmbedder(dimension: 64));
    final first = await svc.reindex();
    expect(first.entriesIndexed, 1);
    expect(first.chunksWritten, greaterThan(0));
    expect(svc.stats().chunks, greaterThan(0));
    expect(svc.stats().dimension, 64);

    final second = await svc.reindex();
    expect(second.entriesIndexed, 0);
    expect(second.entriesSkipped, 1);
    expect(second.chunksWritten, 0);
  }, skip: skip);

  test('检索能命中标题、正文和章节', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '周末',
      body: '在家煮了咖啡，读完了《长安的荔枝》。',
    );
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 2),
      title: '工作',
      body: '和产品对了下季度的排期。',
    );

    final svc = openWith(HashingEmbedder(dimension: 128));
    await svc.reindex();

    final hits = await svc.search('长安的荔枝');
    expect(hits, isNotEmpty);
    expect(hits.first.label, '周末');

    final byTitle = await svc.search('工作');
    expect(byTitle, isNotEmpty);
    expect(byTitle.first.label, '工作');
  }, skip: skip);

  test('只改了其中一篇时，只重建这一篇', () async {
    final a = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '今天写了点东西。',
    );
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 2),
      title: '乙',
      body: '另一篇。',
    );

    final svc = openWith(HashingEmbedder(dimension: 64));
    await svc.reindex();

    entries.saveContent(a.id, body: '今天写了点东西，还加了一段。');
    final report = await svc.reindex();
    expect(report.entriesIndexed, 1);
    expect(report.entriesSkipped, 1);
  }, skip: skip);

  test('附件索引：按文件名和文本内容都能检索到', () async {
    final entry = entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 3),
      title: '报销',
      body: '把发票整理好了。',
    );
    final bytes = Uint8List.fromList('住宿费 380 元 发票号 12345'.codeUnits);
    final blob = await store.storeBytes(bytes, '发票.txt');
    attachments.insert(
      entryId: entry.id,
      sha256: blob.sha256,
      filename: '发票.txt',
      mime: 'text/plain',
      sizeBytes: bytes.length,
    );

    final svc = openWith(HashingEmbedder(dimension: 64));
    final report = await svc.reindex();
    expect(report.attachmentsIndexed, 1);

    final byName = await svc.search('发票');
    expect(byName.any((hit) => hit.isAttachment), isTrue);
    expect(byName.firstWhere((hit) => hit.isAttachment).label, '发票.txt');

    final byContent = await svc.search('380');
    expect(byContent.any((hit) => hit.isAttachment), isTrue);
  }, skip: skip);

  test('换 embedding 模型会整库重建', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );

    final svc = openWith(HashingEmbedder(dimension: 64));
    await svc.reindex();
    expect(svc.stats().dimension, 64);

    final other = openWith(HashingEmbedder(dimension: 128));
    final report = await other.reindex();
    expect(report.rebuilt, isTrue);
    expect(other.stats().dimension, 128);
  }, skip: skip);

  test('统计信息包含模型、维度与切片数', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final svc = openWith(HashingEmbedder(dimension: 32));
    await svc.reindex();
    final stats = svc.stats();
    expect(stats.chunks, greaterThan(0));
    expect(stats.model, 'hash:32');
    expect(stats.dimension, 32);
    expect(stats.indexedAt, isNotEmpty);
  }, skip: skip);
}

String? _locateSqlite3() {
  final fromEnv = Platform.environment['MDIARY_SQLITE_DLL'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  for (final candidate in <String>[
    'build/windows/x64/runner/Release/sqlite3.dll',
    'build/windows/x64/runner/Debug/sqlite3.dll',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}
