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
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;

/// v2.8：附加 md 笔记（可编辑、链接回主文件）。
void main() {
  late Directory sandbox;
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('mdiary_note_');
    db = AppDatabase.inMemory();
    state = _stateFor(db, sandbox);
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('新建附加笔记：写 blob、插链接、可读回', () async {
    final entry = state.entryRepo.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 10),
      title: '主文件',
      body: '正文',
    );
    final note = await state.saveMarkdownNote(
      entry,
      filename: '详细行程.md',
      text: '# 详细\n\n第一天。',
    );
    expect(note.filename, '详细行程.md');
    expect(note.mime, 'text/markdown');
    expect(state.attachmentText(note), contains('第一天'));

    final updated = state.entryRepo.findById(entry.id)!;
    expect(updated.bodyMd, contains('assets/${note.sha256}.md'));
    expect(updated.bodyMd, contains('详细行程.md'));
  });

  test('编辑附加笔记：新 blob、旧引用被替换', () async {
    final entry = state.entryRepo.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 10),
      title: '主文件',
      body: '正文',
    );
    final note = await state.saveMarkdownNote(
      entry,
      filename: 'note.md',
      text: 'old',
    );
    final edited = await state.saveMarkdownNote(
      entry,
      filename: 'note.md',
      text: 'new content',
      existing: note,
    );
    expect(edited.id, note.id);
    expect(edited.sha256, isNot(note.sha256));
    expect(state.attachmentText(edited), 'new content');
    final updated = state.entryRepo.findById(entry.id)!;
    expect(updated.bodyMd, contains('assets/${edited.sha256}.md'));
    expect(updated.bodyMd, isNot(contains('assets/${note.sha256}.md')));
    expect(
      state.attachmentRepo.blobCount(),
      1,
      reason: '编辑后旧 blob 应被清理',
    );
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
