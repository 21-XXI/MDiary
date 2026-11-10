@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/rag_database.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/skill_job.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 2.2：把 soul.md + RAG 语料蒸馏成 skill，写到 db/skill/<时间>/，不覆盖。
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
  late RagDatabase rag;
  late DateTime now;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_skill_');
    libraryRoot = Directory(p.join(sandbox.path, 'lib'))..createSync();
    Directory(p.join(libraryRoot.path, 'db')).createSync(recursive: true);
    db = AppDatabase.open(p.join(libraryRoot.path, 'db', 'mdiary.sqlite'));
    entries = EntryRepository(db);
    tags = TagRepository(db);
    rag = RagDatabase.open(RagService.indexPathFor(libraryRoot.path));
    now = DateTime(2026, 11, 6, 17, 30);
    File(p.join(libraryRoot.path, 'rag', 'soul.md')).writeAsStringSync(
      '# Soul — lib\n\n## 1. 这个人\n\n一个记录生活的人。\n',
    );
  });

  tearDown(() {
    rag.close();
    db.dispose();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  SkillJob jobWith(SkillDistiller distiller) => SkillJob(
    rag: rag,
    entries: entries,
    tags: tags,
    distiller: distiller,
    clock: () => now,
  );

  test('生成 skill：写在 db/skill/<时间>/，带 front matter 与 meta', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '杭州',
      body: '去了西湖。',
    );
    final job = jobWith(FakeSkillDistiller());
    final skill = await job.run();

    expect(skill.markdown, startsWith('---'));
    expect(skill.markdown, contains('Skill:'));
    expect(skill.markdown, contains('name: mdiary-skill-'));
    expect(skill.markdown, contains('description:'));
    expect(File(skill.file).existsSync(), isTrue);
    expect(p.dirname(p.dirname(skill.directory)), libraryRoot.path);
    final meta = File(p.join(skill.directory, 'meta.json'));
    expect(meta.existsSync(), isTrue);
    expect(meta.readAsStringSync(), contains('fake:fake-skill'));
    expect(job.list(), hasLength(1));
  }, skip: skip);

  test('每次生成新目录，不覆盖旧 skill', () async {
    final job = jobWith(FakeSkillDistiller());
    final first = await job.run();
    now = now.add(const Duration(minutes: 1));
    final second = await job.run();
    expect(second.directory, isNot(first.directory));
    expect(File(first.file).existsSync(), isTrue, reason: '旧文件不能被覆盖');
    expect(job.list(), hasLength(2));
    expect(job.list().first.directory, second.directory, reason: '最新的在前');
  }, skip: skip);

  test('同一秒内重复生成也不覆盖（追加 -2 后缀）', () async {
    final job = jobWith(FakeSkillDistiller());
    final first = await job.run();
    final second = await job.run();
    expect(second.directory, isNot(first.directory));
    expect(p.basename(second.directory), endsWith('-2'));
  }, skip: skip);

  test('没有 soul.md 时明确失败', () async {
    File(p.join(libraryRoot.path, 'rag', 'soul.md')).deleteSync();
    await expectLater(
      jobWith(FakeSkillDistiller()).run(),
      throwsA(
        isA<SkillUnavailable>().having(
          (error) => error.message,
          'message',
          contains('soul.md'),
        ),
      ),
    );
  }, skip: skip);

  test('超长输出按 16 KB 预算截断', () async {
    entries.create(
      deviceId: 'd',
      date: DateTime(2026, 11, 1),
      title: '甲',
      body: '正文。',
    );
    final skill = await jobWith(_HugeDistiller()).run();
    expect(skill.bytes, lessThanOrEqualTo(16 * 1024));
    expect(skill.markdown, contains('截断'));
  }, skip: skip);
}

class _HugeDistiller extends FakeSkillDistiller {
  @override
  Future<String> distill({
    required String soul,
    required String digest,
  }) async {
    return List<String>.generate(4000, (i) => '第 $i 条很长的事实描述。').join('\n');
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
