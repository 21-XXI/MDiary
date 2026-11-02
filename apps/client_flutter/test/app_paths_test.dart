@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/app_paths.dart';
import 'package:path/path.dart' as p;

/// 数据目录解析：候选顺序、回退、探针写入。
/// 这里不碰真实的 %APPDATA%，全部用注入的 env / prepare 模拟。
void main() {
  const roaming = r'C:\Users\demo\AppData\Roaming';
  const exeDir = r'D:\apps\mdiary';
  const tempDir = r'C:\Temp';

  test('默认优先 %APPDATA%\\MDiary，且不算回退', () async {
    final tried = <String>[];
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: p.join(exeDir, 'mdiary.exe'),
      tempDir: tempDir,
      prepare: (path) async => tried.add(path),
    );

    expect(tried, <String>[p.join(roaming, 'MDiary')]);
    expect(resolved.path, p.join(roaming, 'MDiary'));
    expect(resolved.source, DataRootSource.platformDefault);
    expect(resolved.isFallback, isFalse);
    expect(resolved.fallbackReason, isNull);
  });

  test('默认目录不可写时退回程序旁的 MDiaryData，并带上原因', () async {
    final tried = <String>[];
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: p.join(exeDir, 'mdiary.exe'),
      tempDir: tempDir,
      prepare: (path) async {
        tried.add(path);
        if (path.startsWith(roaming)) {
          throw FileSystemException(
            'Creation failed',
            p.join(roaming, 'MDiary'),
            const OSError('拒绝访问。', 5),
          );
        }
      },
    );

    expect(resolved.path, p.join(exeDir, AppPaths.portableDirName));
    expect(resolved.source, DataRootSource.portableFallback);
    expect(resolved.isFallback, isTrue);
    expect(resolved.fallbackReason, contains('拒绝访问'));
    expect(resolved.fallbackReason, contains('MDiary'));
    expect(tried, hasLength(2), reason: '第一项失败后才会试第二项');
  });

  test('默认目录与便携目录都不可写时退到临时目录', () async {
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: p.join(exeDir, 'mdiary.exe'),
      tempDir: tempDir,
      prepare: (path) async {
        if (!path.startsWith(tempDir)) throw StateError('只读');
      },
    );

    expect(resolved.path, p.join(tempDir, 'MDiary'));
    expect(resolved.source, DataRootSource.tempFallback);
    expect(resolved.isFallback, isTrue);
  });

  test('全部不可写时抛出带 MDIARY_HOME 提示的错误', () async {
    await expectLater(
      AppPaths.resolve(
        env: const <String, String>{'APPDATA': roaming},
        platformKey: 'windows',
        resolvedExecutable: p.join(exeDir, 'mdiary.exe'),
        tempDir: tempDir,
        prepare: (path) async => throw StateError('拒绝访问'),
      ),
      throwsA(
        isA<DataRootUnavailable>().having(
          (e) => e.message,
          'message',
          allOf(contains('MDIARY_HOME'), contains('拒绝访问')),
        ),
      ),
    );
  });

  test('MDIARY_HOME 显式指定时只认它，不静默换目录', () async {
    const home = r'C:\portable\data';
    final tried = <String>[];
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming, 'MDIARY_HOME': home},
      platformKey: 'windows',
      resolvedExecutable: p.join(exeDir, 'mdiary.exe'),
      tempDir: tempDir,
      prepare: (path) async => tried.add(path),
    );

    expect(tried, <String>[p.join(home, 'MDiary')]);
    expect(resolved.source, DataRootSource.envOverride);
    expect(resolved.isFallback, isFalse);

    // 指定目录不可写时必须报错，而不是把数据写到别处
    await expectLater(
      AppPaths.resolve(
        env: const <String, String>{'MDIARY_HOME': home},
        platformKey: 'windows',
        resolvedExecutable: p.join(exeDir, 'mdiary.exe'),
        tempDir: tempDir,
        prepare: (path) async => throw const FileSystemException('拒绝访问'),
      ),
      throwsA(isA<DataRootUnavailable>()),
    );
  });

  test('空白的 MDIARY_HOME 视为未设置', () async {
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming, 'MDIARY_HOME': '   '},
      platformKey: 'windows',
      tempDir: tempDir,
      prepare: (path) async {},
    );
    expect(resolved.source, DataRootSource.platformDefault);
  });

  test('macOS 与 Linux 的默认目录', () async {
    final mac = await AppPaths.resolve(
      env: const <String, String>{'HOME': '/Users/demo'},
      platformKey: 'macos',
      tempDir: '/tmp',
      prepare: (path) async {},
    );
    expect(
      mac.path,
      p.join('/Users/demo', 'Library', 'Application Support', 'MDiary'),
    );

    final linux = await AppPaths.resolve(
      env: const <String, String>{'HOME': '/home/demo'},
      platformKey: 'linux',
      tempDir: '/tmp',
      prepare: (path) async {},
    );
    expect(linux.path, p.join('/home/demo', '.local', 'share', 'MDiary'));

    final xdg = await AppPaths.resolve(
      env: const <String, String>{
        'HOME': '/home/demo',
        'XDG_DATA_HOME': '/data',
      },
      platformKey: 'linux',
      tempDir: '/tmp',
      prepare: (path) async {},
    );
    expect(xdg.path, p.join('/data', 'MDiary'));
  });

  test('真实探测：目录被创建、探针文件不残留', () async {
    final temp = Directory.systemTemp.createTempSync('mdiary_paths_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final resolved = await AppPaths.resolve(
      env: <String, String>{'MDIARY_HOME': temp.path},
      platformKey: 'windows',
      tempDir: temp.path,
      prepare: null,
    );

    final created = Directory(p.join(temp.path, 'MDiary'));
    expect(created.existsSync(), isTrue);
    expect(resolved.path, created.path);
    expect(
      File(p.join(created.path, AppPaths.probeFileName)).existsSync(),
      isFalse,
      reason: '探针文件用完必须删掉，不能留在数据目录里',
    );
  });

  test('真实探测：目标位置被同名文件占住时判定为不可用', () async {
    final temp = Directory.systemTemp.createTempSync('mdiary_paths_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final blocker = File(p.join(temp.path, 'MDiary'))
      ..writeAsStringSync('not a directory');

    await expectLater(
      AppPaths.resolve(
        env: <String, String>{'MDIARY_HOME': temp.path},
        platformKey: 'windows',
        tempDir: temp.path,
        prepare: null,
      ),
      throwsA(isA<DataRootUnavailable>()),
    );
    expect(blocker.existsSync(), isTrue, reason: '不该删除用户已有的文件');
  });
}
