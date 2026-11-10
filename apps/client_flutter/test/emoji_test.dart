@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/emoji.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:mdiary/ui/emoji_picker.dart';
import 'package:path/path.dart' as p;

/// 2.5.1：表情短代码映射。
void main() {
  group('applyEmoji', () {
    test('常见短代码替换为表情', () {
      expect(applyEmoji('今天很开心 :smile: 和 :heart:', builtinEmoji), contains('😄'));
      expect(applyEmoji(':smile:', builtinEmoji), '😄');
      expect(applyEmoji('中文别名 :微笑:', builtinEmoji), '中文别名 😄');
    });

    test('未知短代码原样保留', () {
      expect(applyEmoji(':unknown_code: 文本', builtinEmoji), ':unknown_code: 文本');
    });

    test('围栏代码块与行内代码不替换', () {
      const source = '正文 :smile:\n```\n:smile:\n```\n` :smile: `';
      final result = applyEmoji(source, builtinEmoji);
      expect(result, contains('正文 😄'));
      expect(result, contains('```\n:smile:\n```'));
      expect(result, contains('` :smile: `'));
    });

    test('自定义映射优先于内置', () {
      final custom = <String, String>{...builtinEmoji, 'smile': '🙂'};
      expect(applyEmoji(':smile:', custom), '🙂');
    });
  });

  group('设置持久化', () {
    late Directory sandbox;
    late AppDatabase db;
    late AppState state;

    setUp(() async {
      sandbox = Directory.systemTemp.createTempSync('mdiary_emoji_');
      db = AppDatabase.inMemory();
      state = _stateFor(db, sandbox);
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      db.dispose();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('新增自定义并覆盖内置，删除后恢复内置', () {
      expect(state.emojiMap['smile'], '😄');
      state.setEmoji('smile', '🙂');
      expect(state.emojiMap['smile'], '🙂');
      expect(state.emojiCustom['smile'], '🙂');

      state.setEmoji('cat2', '🐈');
      expect(state.emojiMap['cat2'], '🐈');

      state.removeEmoji('smile');
      expect(state.emojiMap['smile'], '😄');
      state.removeEmoji('cat2');
      expect(state.emojiMap.containsKey('cat2'), isFalse);
    });

    test('重新打开后自定义仍在（meta 持久化）', () async {
      state.setEmoji('cat2', '🐈');
      final second = _stateFor(db, sandbox);
      await second.bootstrap();
      expect(second.emojiMap['cat2'], '🐈');
      second.dispose();
    });
  });

  testWidgets('表情面板插入短代码', (tester) async {
    final sandbox = Directory.systemTemp.createTempSync('mdiary_emoji_ui_');
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final state = _stateFor(db, sandbox);
    await state.bootstrap();
    addTearDown(state.dispose);

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showEmojiPicker(context, state: state);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('表情'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'smile');
    await tester.pumpAndSettle();
    await tester.tap(find.text(':smile:').first);
    await tester.pumpAndSettle();
    expect(picked, 'smile');
  });
}

AppState _stateFor(AppDatabase db, Directory sandbox) {
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
  );
}
