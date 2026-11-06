@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/rag_database.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/soul_job.dart';
import 'package:mdiary/rag/summarizer.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

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
  late TagRepository tags;
  late AttachmentRepository attachments;
  late RagDatabase rag;
  late DateTime now;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_soul_');
    libraryRoot = Directory(p.join(sandbox.path, 'lib'))..createSync();
    Directory(p.join(libraryRoot.path, 'db')).createSync(recursive: true);
    db = AppDatabase.open(p.join(libraryRoot.path, 'db', 'mdiary.sqlite'));
    entries = EntryRepository(db);
    tags = TagRepository(db);
    attachments = AttachmentRepository(db);
    rag = RagDatabase.open(RagService.indexPathFor(libraryRoot.path));
    now = DateTime(2026, 11, 6, 10, 0);
  });

  tearDown(() {
    rag.close();
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  SoulJob jobWith(Summarizer summarizer) => SoulJob(
    rag: rag,
    entries: entries,
    tags: tags,
    attachments: attachments,
    summarizer: summarizer,
    clock: () => now,
  );

  File soulFile() => File(p.join(libraryRoot.path, 'rag', 'soul.md'));

  test('生成 soul.md：7 个小节、≤8 KB、并留上一版备份', () async {
    final a = entries.create(
      deviceId: 'd',
      date: DateTime(2024, 5, 1),
      title: '入职',
      body: '第一天上班。',
    );
    tags.setTags(a.id, <String>['工作']);
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 10, 20),
      title: '杭州',
      body: '去了西湖。',
    );

    final job = jobWith(FakeSummarizer());
    final report = await job.generate();

    expect(report.generated, isTrue);
    expect(report.bytes, lessThanOrEqualTo(8192));
    expect(soulFile().existsSync(), isTrue);
    final text = soulFile().readAsStringSync();
    for (final header in <String>[
      '## 1. 这个人',
      '## 2. 长期主题',
      '## 3. 重要的人 · 地点 · 项目',
      '## 4. 写作与语气',
      '## 5. 时间线（每年一行）',
      '## 6. 近期状态（最近 30 天）',
      '## 7. 如何检索这个库',
    ]) {
      expect(text, contains(header), reason: '缺少 $header');
    }
    expect(text, contains('2024：1 篇'));
    expect(text, contains('2026：1 篇'));
    expect(text, contains('工作'));

    await job.generate();
    expect(File('${soulFile().path}.bak').existsSync(), isTrue);
  }, skip: skip);

  test('触发条件：首次生成、7 天后、或新增 20 篇', () async {
    final job = jobWith(FakeSummarizer());
    expect(await job.isDue(), isTrue);

    await job.generate();
    expect(await job.isDue(), isFalse);

    now = now.add(const Duration(days: 8));
    expect(await job.isDue(), isTrue);

    now = DateTime(2026, 11, 20, 9, 0);
    await job.generate();
    expect(await job.isDue(), isFalse);

    for (var i = 0; i < 20; i++) {
      entries.create(
        deviceId: 'd',
        date: DateTime(2026, 11, 20),
        title: '第 $i 篇',
        body: '正文。',
      );
    }
    expect(await job.isDue(), isTrue, reason: '新增 20 篇应触发重新生成');
  }, skip: skip);

  test('模型不可用时写统计版，不抛错', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final job = SoulJob(
      rag: rag,
      entries: entries,
      tags: tags,
      attachments: attachments,
      summarizer: _UnavailableSummarizer(),
      clock: () => now,
    );
    final report = await job.generate();

    expect(report.generated, isTrue);
    expect(report.model, 'system');
    final text = soulFile().readAsStringSync();
    expect(text, contains('统计版'));
    expect(text, contains('## 7. 如何检索这个库'));
  }, skip: skip);

  test('空库也能生成（写「还没有日记」）', () async {
    final job = jobWith(FakeSummarizer());
    final report = await job.generate();
    expect(report.generated, isTrue);
    expect(report.entries, 0);
    expect(soulFile().readAsStringSync(), contains('还没有日记'));
  }, skip: skip);

  test('模型输出过长时按 8 KB 截断', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final job = SoulJob(
      rag: rag,
      entries: entries,
      tags: tags,
      attachments: attachments,
      summarizer: _HugeSummarizer(),
      clock: () => now,
    );
    final report = await job.generate();
    expect(report.bytes, lessThanOrEqualTo(8192));
    expect(soulFile().readAsStringSync(), contains('截断'));
  }, skip: skip);
}

class _UnavailableSummarizer extends FakeSummarizer {
  @override
  Future<bool> isAvailable() async => false;
}

class _HugeSummarizer extends FakeSummarizer {
  @override
  Future<SoulSections> generateSoul({required String digest}) async {
    final long = List<String>.generate(200, (i) => '第 $i 句很长的概括。').join();
    return SoulSections(
      person: long,
      themes: long,
      peoplePlaces: long,
      style: long,
      recent: long,
    );
  }
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
