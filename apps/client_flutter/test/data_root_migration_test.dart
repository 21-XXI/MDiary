@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/data_root_migration.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory source;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mdiary_migration_');
    source = Directory(p.join(sandbox.path, 'old'))..createSync();
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  void seedSource() {
    seedDatabaseInto(source);
    File(p.join(source.path, 'attachments', 'ab', 'abcdef.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(source.path, 'logs', 'error.log'))
      ..createSync(recursive: true)
      ..writeAsStringSync('boom');
    File(p.join(source.path, 'settings.json')).writeAsStringSync('{"k":1}');
  }

  test('复制数据库、附件、日志与 settings，并校验大小', () async {
    seedSource();
    final target = p.join(sandbox.path, 'new');

    final result =
        await DataRootMigration(source: source.path, target: target).run();

    expect(result.target, p.canonicalize(target));
    expect(result.files, 4);
    expect(result.bytes, greaterThan(0));
    expect(
      File(DataRootMigration.databaseFileIn(target)).readAsStringSync(),
      'sqlite-bytes',
    );
    expect(
      File(p.join(target, 'attachments', 'ab', 'abcdef.png')).readAsBytesSync(),
      <int>[1, 2, 3],
    );
    expect(File(p.join(target, 'logs', 'error.log')).readAsStringSync(), 'boom');
    expect(File(p.join(target, 'settings.json')).existsSync(), isTrue);
    expect(
      Directory(source.path).existsSync(),
      isTrue,
      reason: '复制阶段不删源目录',
    );
  });

  test('目标目录已有 mdiary.sqlite 时拒绝（避免覆盖别人的库）', () async {
    seedSource();
    final target = Directory(p.join(sandbox.path, 'other'))..createSync();
    seedDatabaseInto(target, content: 'existing');

    await expectLater(
      DataRootMigration(source: source.path, target: target.path).run(),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('已经有 MDiary 数据'),
        ),
      ),
    );
    expect(
      File(DataRootMigration.databaseFileIn(target.path)).readAsStringSync(),
      'existing',
      reason: '目标的库不能被改写',
    );
  });

  test('目标目录有无关文件时拒绝', () async {
    seedSource();
    final target = Directory(p.join(sandbox.path, 'busy'))..createSync();
    File(p.join(target.path, '照片.jpg')).writeAsBytesSync(<int>[1]);

    await expectLater(
      DataRootMigration(source: source.path, target: target.path).run(),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('不是空目录'),
        ),
      ),
    );
  });

  test('目标与源相同 / 互相嵌套时拒绝', () async {
    seedSource();

    await expectLater(
      DataRootMigration(source: source.path, target: source.path).run(),
      throwsA(isA<DataRootMigrationException>()),
    );

    final inside = p.join(source.path, 'sub');
    await expectLater(
      DataRootMigration(source: source.path, target: inside).run(),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('里面'),
        ),
      ),
    );

    await expectLater(
      DataRootMigration(source: p.join(source.path, 'attachments'), target: sandbox.path).run(),
      throwsA(isA<DataRootMigrationException>()),
    );
  });

  test('源目录没有数据库时报错', () async {
    await expectLater(
      DataRootMigration(source: source.path, target: p.join(sandbox.path, 'new'))
          .run(),
      throwsA(
        isA<DataRootMigrationException>().having(
          (e) => e.message,
          'message',
          contains('没有 mdiary.sqlite'),
        ),
      ),
    );
  });

  test('删旧目录：只删本程序的文件，无关文件保留', () async {
    seedSource();
    File(p.join(source.path, 'notes.txt')).writeAsStringSync('mine');

    final removed = await DataRootMigration.removeOldRoot(
      source.path,
      exePath: p.join(sandbox.path, 'app', 'mdiary.exe'),
    );

    expect(removed, contains('db'));
    expect(removed, contains('attachments'));
    expect(removed, contains('logs'));
    expect(File(DataRootMigration.databaseFileIn(source.path)).existsSync(), isFalse);
    expect(File(p.join(source.path, 'notes.txt')).existsSync(), isTrue);
    expect(
      FileSystemEntity.typeSync(source.path),
      isNot(FileSystemEntityType.notFound),
      reason: '还有无关文件时不能删整个目录',
    );
  });

  test('删旧目录：删空后连目录一起删；目录里装着 exe 时不动', () async {
    seedSource();
    final removed = await DataRootMigration.removeOldRoot(
      source.path,
      exePath: p.join(sandbox.path, 'app', 'mdiary.exe'),
    );
    expect(removed, contains('.'));
    expect(source.existsSync(), isFalse);

    // exe 就在数据目录里（极端便携用法）：一个文件都不许删
    final portable = Directory(p.join(sandbox.path, 'portable'))..createSync();
    seedDatabaseInto(portable);
    final untouched = await DataRootMigration.removeOldRoot(
      portable.path,
      exePath: p.join(portable.path, 'mdiary.exe'),
    );
    expect(untouched, isEmpty);
    expect(
      File(DataRootMigration.databaseFileIn(portable.path)).existsSync(),
      isTrue,
    );
  });
}

void seedDatabaseInto(Directory dir, {String content = 'sqlite-bytes'}) {
  final file = File(DataRootMigration.databaseFileIn(dir.path));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
