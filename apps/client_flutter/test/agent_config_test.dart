@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/agent_config.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;

/// v2.7：Agent 配置（步数/权限/日志）。
void main() {
  test('配置 JSON 往返与步数范围', () {
    const config = AgentConfig(maxSteps: 7, allowSearchDiary: true);
    final loaded = AgentConfig.fromJson(
      jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
    );
    expect(loaded.maxSteps, 7);
    expect(loaded.allowSearchDiary, isTrue);
    expect(
      AgentConfig.fromJson(<String, Object?>{'max_steps': 99}).maxSteps,
      10,
    );
  });

  test('运行日志追加/截断/清空', () {
    final sandbox = Directory.systemTemp.createTempSync('mdiary_runs_');
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final log = AgentRunLog(AgentRunLog.pathFor(sandbox.path));
    for (var i = 0; i < 3; i++) {
      log.append(
        AgentRun(
          kind: 'segment',
          startedAt: DateTime(2026, 11, 10, 10, i),
          steps: i + 1,
          ok: true,
          message: 'run $i',
        ),
      );
    }
    expect(log.load(), hasLength(3));
    expect(log.load(limit: 2), hasLength(2));
    expect(log.load().last.steps, 3);
    log.clear();
    expect(log.load(), isEmpty);
  });

  test('分词失败会按步数重试，成功后在日志里记 2 步', () async {
    final sandbox = Directory.systemTemp.createTempSync('mdiary_agent_');
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final source = Directory(p.join(sandbox.path, 'src'))..createSync();
    File(p.join(source.path, 'a.md')).writeAsStringSync('2026-11-06 去了西湖。');
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);

    var calls = 0;
    final state = _stateFor(db, sandbox, (prompt) async {
      calls++;
      if (calls == 1) return '不是 JSON';
      return '{"days":[{"date":"2026-11-06","title":"西湖","body":"去了西湖。"}]}';
    });
    await state.bootstrap();
    addTearDown(state.dispose);

    state.setAgentConfig(const AgentConfig(maxSteps: 2));
    final plan = await state.planSegmentation(source.path);
    expect(plan.days, hasLength(1));
    expect(calls, 2);
    final runs = state.loadAgentRuns();
    expect(runs, hasLength(1));
    expect(runs.single.ok, isTrue);
    expect(runs.single.steps, 2);
  });

  test('关闭权限后拒绝执行', () async {
    final sandbox = Directory.systemTemp.createTempSync('mdiary_agent_perm_');
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final state = _stateFor(db, sandbox, (prompt) async => '{}');
    await state.bootstrap();
    addTearDown(state.dispose);

    state.setAgentConfig(
      const AgentConfig(allowReadFolder: false, logEnabled: false),
    );
    await expectLater(
      state.planSegmentation(sandbox.path),
      throwsA(isA<Exception>()),
    );

    state.setAgentConfig(
      const AgentConfig(allowReadSkill: false, logEnabled: false),
    );
    await expectLater(state.askMemory('hi'), throwsA(isA<StateError>()));
  });
}

AppState _stateFor(
  AppDatabase db,
  Directory sandbox,
  Future<String> Function(String prompt) complete,
) {
  final entries = EntryRepository(db);
  final attachments = AttachmentRepository(db);
  final store = AttachmentStore(
    Directory(p.join(sandbox.path, 'attachments')),
    blobs: attachments,
  );
  return AppState(
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
    agentConfigStore: AgentConfigStore(path: p.join(sandbox.path, 'agents.json')),
    segmentCompleterOverride: complete,
    memoryCompleterOverride: complete,
  );
}
