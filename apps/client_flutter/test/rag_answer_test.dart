@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/answer.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/rag_settings.dart';
import 'package:mdiary/rag/summarizer.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;

/// 2.0.2：问答生成（流式）与「交互 / 生成模型」设置。
void main() {
  late Directory sandbox;
  late File settingsFile;
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('mdiary_ask_');
    settingsFile = File(p.join(sandbox.path, 'settings.json'));
    db = AppDatabase.inMemory();
    final entries = EntryRepository(db);
    final attachments = AttachmentRepository(db);
    final store = AttachmentStore(
      Directory(p.join(sandbox.path, 'attachments')),
      blobs: attachments,
    );
    state = AppState(
      db: db,
      entryRepo: entries,
      attachmentRepo: attachments,
      metaRepo: MetaRepository(db),
      tagRepository: TagRepository(db),
      store: store,
      markdownIo: MarkdownIo(
        entries: entries,
        attachments: attachments,
        store: store,
        tags: TagRepository(db),
      ),
      filePicker: () async => null,
      directoryPicker: (title) async => null,
      dataRootPath: sandbox.path,
      ragSettingsStore: RagSettingsStore(path: settingsFile.path),
      ragAnswererOverride: FakeAnswerer(),
      ragSummarizerOverride: FakeSummarizer(),
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('模型设置：读写 settings.json，并影响摘要/问答的模型 id', () async {
    // 覆盖版（测试注入）优先
    expect(state.ragSummarizer.modelId, 'fake:fake');
    expect(state.ragAnswerer.modelId, 'fake:fake-answer');

    state.updateRagSettings(
      state.ragSettings.copyWith(
        askModel: 'qwen3:4b',
        generateModel: 'qwen3:14b',
        embedModel: 'bge-m3',
        baseUrl: 'http://127.0.0.1:11434',
      ),
    );

    final reloaded = RagSettingsStore(path: settingsFile.path).load();
    expect(reloaded.askModel, 'qwen3:4b');
    expect(reloaded.generateModel, 'qwen3:14b');

    // 不注入时，取的是设置里的模型
    final plain = AppState(
      db: db,
      entryRepo: state.entryRepo,
      attachmentRepo: state.attachmentRepo,
      metaRepo: state.metaRepo,
      tagRepository: state.tagRepo,
      store: state.store,
      markdownIo: state.markdownIo,
      filePicker: () async => null,
      directoryPicker: (title) async => null,
      dataRootPath: sandbox.path,
      ragSettingsStore: RagSettingsStore(path: settingsFile.path),
    );
    expect(plain.ragSummarizer.modelId, 'ollama:qwen3:14b');
    expect(plain.ragAnswerer.modelId, 'ollama:qwen3:4b');
    plain.dispose();
  }, skip: false);

  test('问答：FakeAnswerer 流式输出，带 [日期-标题] 引用', () async {
    final hits = <RagHit>[
      RagHit(
        chunkId: 'c1',
        kind: 'entry',
        label: '杭州出差',
        text: '去了西湖，风很大。',
        snippet: '去了西湖，风很大。',
        date: DateTime(2026, 11, 1),
        score: 0.9,
        entryId: 'e1',
      ),
    ];
    final chunks = await state.streamAnswer('去年在杭州做了什么？', hits).toList();
    final text = chunks.join();
    expect(chunks.length, greaterThan(1), reason: '应该是流式多片');
    expect(text, contains('[2026-11-01-杭州出差]'));
  }, skip: false);

  test('提示词包含来源与引用要求', () {
    final prompt = OllamaAnswerer.buildPrompt(
      question: '去年去了哪里？',
      sources: <AnswerSource>[
        AnswerSource(
          label: '杭州出差',
          date: DateTime(2026, 11, 1),
          text: '去了西湖。',
          kind: 'entry',
        ),
      ],
    );
    expect(prompt, contains('只根据'));
    expect(prompt, contains('[日期-标题]'));
    expect(prompt, contains('2026-11-01-杭州出差'));
    expect(prompt, contains('去了西湖'));
  });

  test('Fake 回答在没有任何来源时给出兜底话术', () async {
    final chunks = await FakeAnswerer()
        .streamAnswer(question: '随便问问', sources: const <AnswerSource>[])
        .toList();
    expect(chunks.join(), contains('没有在日记里找到'));
  });
}
