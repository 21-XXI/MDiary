@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/app_paths.dart';
import 'package:path/path.dart' as p;

/// 数据目录解析：候选顺序、回退、位置记忆、探针写入。
/// 这里不碰真实的 %APPDATA%，全部用注入的 env / prepare 模拟。
void main() {
  const roaming = r'C:\Users\demo\AppData\Roaming';
  const exeDir = r'D:\apps\mdiary';
  const exePath = r'D:\apps\mdiary\mdiary.exe';
  const tempDir = r'C:\Temp';

  final portableRoot = p.join(exeDir, AppPaths.portableDirName);
  final appDataRoot = p.join(roaming, AppPaths.dataDirName);

  test('默认落在 exe 同目录的 MDiaryData', () async {
    final tried = <String>[];
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: exePath,
      tempDir: tempDir,
      prepare: (path) async => tried.add(path),
    );

    expect(tried, <String>[portableRoot]);
    expect(resolved.path, portableRoot);
    expect(resolved.source, DataRootSource.portableDefault);
    expect(resolved.isFallback, isFalse);
    expect(resolved.fallbackReason, isNull);
  });

  test('记住的目录优先于便携默认', () async {
    const chosen = r'E:\我的日记';
    final tried = <String>[];
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: exePath,
      tempDir: tempDir,
      storedLocation: chosen,
      prepare: (path) async => tried.add(path),
    );

    expect(tried.single, p.canonicalize(chosen));
    expect(resolved.source, DataRootSource.userChosen);
    expect(resolved.isFallback, isFalse);
  });

  test('记住的目录不可用时回退到便携默认，并说明原因', () async {
    const chosen = r'E:\我的日记';
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: exePath,
      tempDir: tempDir,
      storedLocation: chosen,
      prepare: (path) async {
        if (path.toLowerCase().startsWith('e:')) {
          throw FileSystemException(
            'Creation failed',
            path,
            const OSError('拒绝访问。', 5),
          );
        }
      },
    );

    expect(resolved.path, portableRoot);
    expect(resolved.source, DataRootSource.portableDefault);
    expect(resolved.isFallback, isTrue);
    expect(resolved.fallbackReason, contains('拒绝访问'));
    expect(resolved.fallbackReason, contains('我的日记'));
  });

  test('便携目录不可写时退到 %APPDATA%，再不行退到临时目录', () async {
    final toAppData = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: exePath,
      tempDir: tempDir,
      prepare: (path) async {
        if (path.startsWith('D:')) throw StateError('只读');
      },
    );
    expect(toAppData.path, appDataRoot);
    expect(toAppData.source, DataRootSource.appDataFallback);
    expect(toAppData.isFallback, isTrue);

    final toTemp = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable: exePath,
      tempDir: tempDir,
      prepare: (path) async {
        if (!path.startsWith(tempDir)) throw StateError('只读');
      },
    );
    expect(toTemp.path, p.join(tempDir, AppPaths.dataDirName));
    expect(toTemp.source, DataRootSource.tempFallback);
    expect(toTemp.isFallback, isTrue);
  });

  test('全部不可写时抛出带 MDIARY_HOME 提示的错误', () async {
    await expectLater(
      AppPaths.resolve(
        env: const <String, String>{'APPDATA': roaming},
        platformKey: 'windows',
        resolvedExecutable: exePath,
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
      resolvedExecutable: exePath,
      tempDir: tempDir,
      prepare: (path) async => tried.add(path),
    );

    expect(tried, <String>[p.join(home, AppPaths.dataDirName)]);
    expect(resolved.source, DataRootSource.envOverride);
    expect(resolved.isFallback, isFalse);

    await expectLater(
      AppPaths.resolve(
        env: const <String, String>{'MDIARY_HOME': home},
        platformKey: 'windows',
        resolvedExecutable: exePath,
        tempDir: tempDir,
        prepare: (path) async => throw const FileSystemException('拒绝访问'),
      ),
      throwsA(isA<DataRootUnavailable>()),
    );
  });

  test('测试宿主（flutter_tester）没有程序目录，跳过便携默认', () async {
    final tried = <String>[];
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming},
      platformKey: 'windows',
      resolvedExecutable:
          r'C:\src\flutter\bin\cache\artifacts\engine\flutter_tester.exe',
      tempDir: tempDir,
      prepare: (path) async => tried.add(path),
    );

    expect(tried.single, appDataRoot);
    expect(resolved.source, DataRootSource.appDataFallback);
  });

  test('空白的 MDIARY_HOME / 记住位置都视为未设置', () async {
    final resolved = await AppPaths.resolve(
      env: const <String, String>{'APPDATA': roaming, 'MDIARY_HOME': '   '},
      platformKey: 'windows',
      resolvedExecutable: exePath,
      tempDir: tempDir,
      storedLocation: '  ',
      prepare: (path) async {},
    );
    expect(resolved.source, DataRootSource.portableDefault);
  });

  test('macOS 与 Linux 的兜底目录', () async {
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
    );

    final created = Directory(p.join(temp.path, AppPaths.dataDirName));
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
    final blocker = File(p.join(temp.path, AppPaths.dataDirName))
      ..writeAsStringSync('not a directory');

    await expectLater(
      AppPaths.resolve(
        env: <String, String>{'MDIARY_HOME': temp.path},
        platformKey: 'windows',
        tempDir: temp.path,
      ),
      throwsA(isA<DataRootUnavailable>()),
    );
    expect(blocker.existsSync(), isTrue, reason: '不该删除用户已有的文件');
  });

  test('DataLocationStore 读写往返；没有程序目录时写入报错', () async {
    final temp = Directory.systemTemp.createTempSync('mdiary_loc_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final store = DataLocationStore(temp.path);
    expect(store.read(), isNull, reason: '文件不存在视为没设置过');

    await store.write(r'D:\data\MDiary');
    expect(store.read(), r'D:\data\MDiary');
    expect(File(store.filePath!).readAsStringSync(), r'D:\data\MDiary');

    const none = DataLocationStore(null);
    expect(none.read(), isNull);
    await expectLater(
      none.write(r'D:\data'),
      throwsA(isA<DataRootUnavailable>()),
    );
  });
}
