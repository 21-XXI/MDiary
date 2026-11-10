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
import 'package:mdiary/rag/memory_chat.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;

/// v2.7：记忆对话（只用 skill，按库持久化）。
void main() {
  test('提示词包含 skill、历史与问题', () {
    final prompt = buildMemoryPrompt(
      skill: '# Skill: 我\n\n喜欢旅行。',
      history: <MemoryMessage>[
        MemoryMessage(fromUser: true, text: '你好', createdAt: _t),
        MemoryMessage(fromUser: false, text: '你好呀', createdAt: _t),
      ],
      question: '我去过哪？',
    );
    expect(prompt, contains('喜欢旅行'));
    expect(prompt, contains('用户：你好'));
    expect(prompt, contains('助手：你好呀'));
    expect(prompt, contains('用户：我去过哪？'));
  });

  test('没有 skill 时提示词不注入预设角色', () {
    final prompt = buildMemoryPrompt(
      skill: '',
      history: const <MemoryMessage>[],
      question: '你好',
    );
    expect(prompt, isNot(contains('记忆助手')));
    expect(prompt, isNot(contains('资料')));
    expect(prompt, contains('用户：你好'));
  });

  test('JSONL 追加/读取/清空', () {
    final sandbox = Directory.systemTemp.createTempSync('mdiary_mem_');
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final store = MemoryChatStore(
      MemoryChatStore.pathFor(p.join(sandbox.path, 'lib')),
    );
    store.append(MemoryMessage(fromUser: true, text: 'a', createdAt: _t));
    store.append(MemoryMessage(fromUser: false, text: 'b', createdAt: _t));
    expect(store.load().map((m) => m.text), <String>['a', 'b']);
    store.clear();
    expect(store.load(), isEmpty);
  });

  group('AppState', () {
    late Directory sandbox;
    late AppState state;

    setUp(() async {
      sandbox = Directory.systemTemp.createTempSync('mdiary_mem_state_');
      final db = AppDatabase.inMemory();
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
        memoryCompleterOverride: (prompt) async => '我记得那次旅行。',
      );
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      state.db.dispose();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('可选择模型默认预设并按库保存', () async {
      state.setMemorySkill(AppState.memoryModelPreset);
      expect(state.memorySkillSelection, AppState.memoryModelPreset);
      expect(state.memorySkillName, '模型默认预设');
    });

    test('没有 skill 时走普通对话，不报错', () async {
      final reply = await state.askMemory('你好');
      expect(reply.text, '我记得那次旅行。');
      expect(state.loadMemoryChat(), hasLength(2));
    });

    test('生成 skill 后可对话，消息按库持久化', () async {
      final skillDir = Directory(
        p.join(sandbox.path, 'db', 'skill', 's1'),
      )..createSync(recursive: true);
      File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync(
        '---\nname: 我的skill\n---\n\n# Skill: 我\n\n喜欢旅行。',
      );
      final reply = await state.askMemory('我去过哪？');
      expect(reply.text, '我记得那次旅行。');
      final messages = state.loadMemoryChat();
      expect(messages.map((m) => m.text), <String>[
        '我去过哪？',
        '我记得那次旅行。',
      ]);
      state.clearMemoryChat();
      expect(state.loadMemoryChat(), isEmpty);
    });
  });
}

final DateTime _t = DateTime(2026, 11, 10);
