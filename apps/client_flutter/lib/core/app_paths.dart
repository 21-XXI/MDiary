import 'dart:io';

import 'package:path/path.dart' as p;

/// 数据根目录的来源。
enum DataRootSource {
  /// `MDIARY_HOME` 环境变量（测试 / 便携模式，显式指定）。
  envOverride,

  /// 用户在设置页选择并记住的目录。
  userChosen,

  /// 默认：可执行文件同目录下的 `MDiaryData`（绿色版，不写系统目录）。
  portableDefault,

  /// 可执行文件目录不可写时退回 `%APPDATA%\MDiary`。
  appDataFallback,

  /// 再不可写时退回系统临时目录（重启后可能被清理）。
  tempFallback,
}

/// 一次目录解析的结果。
class DataRoot {
  const DataRoot({
    required this.path,
    required this.source,
    this.fallbackReason,
  });

  final String path;
  final DataRootSource source;

  /// 仅在实际跳过了更优先的候选时非空：原计划目录 + 失败原因。
  final String? fallbackReason;

  /// 是否没落在首选位置上（设置页 / 首页要提示）。
  bool get isFallback => fallbackReason != null;
}

/// 所有候选目录都不可用时抛出，消息直接面向用户。
class DataRootUnavailable implements Exception {
  const DataRootUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `mdiary-location.txt` 的读写：记住用户选过的数据目录。
///
/// 默认放在可执行文件旁边（绿色版跟着 exe 走，搬走整个目录即可）。
/// [directoryPath] 为 null 表示当前环境没有稳定的程序目录（flutter_tester / dart run）。
class DataLocationStore {
  const DataLocationStore(this.directoryPath);

  final String? directoryPath;

  /// 生产环境：exe 同目录。
  factory DataLocationStore.portable() =>
      DataLocationStore(AppPaths.exeDirectory);

  String? get filePath => directoryPath == null
      ? null
      : p.join(directoryPath!, AppPaths.locationFileName);

  /// 读不到 / 空文件都当作「没设置过」。
  String? read() {
    final path = filePath;
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync().trim();
    return text.isEmpty ? null : text;
  }

  /// 写入并读回校验；写不了（exe 目录只读）直接抛错，
  /// 避免「换了目录但下次启动又回去」。
  Future<void> write(String dataRoot) async {
    final path = filePath;
    if (path == null) {
      throw const DataRootUnavailable('当前运行环境没有可用的程序目录，无法记住新的数据目录');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(dataRoot, flush: true);
    final readBack = file.readAsStringSync().trim();
    if (readBack != dataRoot) {
      throw DataRootUnavailable('无法写入 $path（读回内容不一致），新的数据目录没有被记住');
    }
  }
}

/// 应用数据目录解析。
///
/// 解析顺序：
/// 1. `MDIARY_HOME` 环境变量（显式指定，只有它一个候选，写不了就报错）；
/// 2. `mdiary-location.txt` 里记住的目录（设置页改过路径）；
/// 3. `mdiary.exe` 同目录的 `MDiaryData`（默认，绿色版）；
/// 4. `%APPDATA%\MDiary`（exe 在 Program Files 等不可写位置时的兼容路径）；
/// 5. 系统临时目录。
///
/// 每个候选都真写一次探针文件才认定可用：`create` 对已存在的只读目录不会报错，
/// 只靠它会把问题推迟到打开数据库时才暴露。
class AppPaths {
  AppPaths._();

  static const String dataDirName = 'MDiary';
  static const String portableDirName = 'MDiaryData';
  static const String locationFileName = 'mdiary-location.txt';
  static const String probeFileName = '.write_probe';

  /// 数据库单独放一个子目录：备份/导入时一眼能认出，不和缓存、日志混在一起。
  static const String databaseDirName = 'db';
  static const String databaseFileName = 'mdiary.sqlite';

  /// 没有稳定「程序目录」的宿主进程（单测 / dart run），不能拿它做便携目录。
  static const List<String> _testHosts = <String>[
    'flutter_tester',
    'dart',
    'flutter',
  ];

  static late Directory root;

  /// 位置指针的存放处；测试可替换成临时目录。
  static DataLocationStore? locationStore;

  static DataRoot? _resolution;
  static bool _initialized = false;

  /// 当前数据根目录的解析结果（未 init 时为 null）。
  static DataRoot? get resolution => _resolution;

  /// 是否退到了首选位置以外。
  static bool get isFallback => _resolution?.isFallback ?? false;

  /// 回退原因；未回退时为 null。
  static String? get fallbackReason => _resolution?.fallbackReason;

  /// 可执行文件所在目录；flutter_tester / dart 宿主下为 null。
  static String? get exeDirectory =>
      _exeDirectoryOf(Platform.resolvedExecutable);

  static Future<void> init() async {
    if (_initialized) return;
    locationStore ??= DataLocationStore.portable();
    final resolved = await resolve(
      env: Platform.environment,
      platformKey: _platformKey(),
      resolvedExecutable: Platform.resolvedExecutable,
      tempDir: Directory.systemTemp.path,
      storedLocation: locationStore?.read(),
    );
    adopt(resolved);
  }

  /// 直接采用一个解析结果（切换目录时也走这里）。
  static void adopt(DataRoot resolved) {
    root = Directory(resolved.path);
    _resolution = resolved;
    _initialized = true;
  }

  /// 迁移到用户选择的目录：先写位置指针再切换，保证重启后还在新位置。
  static Future<void> switchTo(String dataRoot) async {
    final normalized = p.canonicalize(dataRoot);
    await prepare(normalized);
    final store = locationStore ?? DataLocationStore.portable();
    await store.write(normalized);
    locationStore = store;
    adopt(DataRoot(path: normalized, source: DataRootSource.userChosen));
  }

  /// 数据库文件位置：`<数据目录>/db/mdiary.sqlite`。
  static String get databaseFile => databaseFileIn(root.path);

  static String databaseFileIn(String rootPath) =>
      p.join(rootPath, databaseDirName, databaseFileName);

  static String get databaseDirectory => p.join(root.path, databaseDirName);

  /// 老版本把 `mdiary.sqlite` 直接放在数据目录根：升级到 `db/` 子目录（幂等）。
  ///
  /// 在打开数据库之前调用；WAL/SHM 一起搬，避免丢事务。
  static void migrateLegacyDatabaseLayout() {
    final target = File(databaseFile);
    if (target.existsSync()) return;
    final legacy = File(p.join(root.path, databaseFileName));
    if (!legacy.existsSync()) return;
    Directory(target.parent.path).createSync(recursive: true);
    for (final suffix in <String>['', '-wal', '-shm']) {
      final file = File('${legacy.path}$suffix');
      if (!file.existsSync()) continue;
      file.renameSync('${target.path}$suffix');
    }
  }

  static String get attachmentsPath => p.join(root.path, 'attachments');

  static Directory get attachmentsDir => Directory(attachmentsPath);

  static String get logsPath => p.join(root.path, 'logs');

  static String get settingsFile => p.join(root.path, 'settings.json');

  /// 按优先级探测可写的数据目录。所有参数显式传入，便于在单测里替换环境。
  ///
  /// [prepare] 默认是「建目录 + 写探针文件」，测试可注入抛异常的版本模拟只读目录。
  static Future<DataRoot> resolve({
    required Map<String, String> env,
    required String platformKey,
    required String tempDir,
    String? resolvedExecutable,
    String? storedLocation,
    Future<void> Function(String path)? prepare,
  }) async {
    final preparePath = prepare ?? AppPaths.prepare;
    final override = (env['MDIARY_HOME'] ?? '').trim();
    final candidates = <_Candidate>[];

    if (override.isNotEmpty) {
      // 用户显式指定就只认它：不静默换目录，否则数据会跑到意想不到的地方。
      candidates.add(
        _Candidate(p.join(override, dataDirName), DataRootSource.envOverride),
      );
    } else {
      final remembered = (storedLocation ?? '').trim();
      if (remembered.isNotEmpty) {
        candidates.add(
          _Candidate(p.canonicalize(remembered), DataRootSource.userChosen),
        );
      }
      final exeDir = _exeDirectoryOf(resolvedExecutable);
      if (exeDir != null) {
        candidates.add(
          _Candidate(
            p.join(exeDir, portableDirName),
            DataRootSource.portableDefault,
          ),
        );
      }
      candidates.add(
        _Candidate(
          p.join(_platformBase(env, platformKey), dataDirName),
          DataRootSource.appDataFallback,
        ),
      );
      candidates.add(
        _Candidate(p.join(tempDir, dataDirName), DataRootSource.tempFallback),
      );
    }

    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        await preparePath(candidate.path);
        return DataRoot(
          path: candidate.path,
          source: candidate.source,
          fallbackReason: failures.isEmpty ? null : failures.join('；'),
        );
      } catch (error) {
        failures.add('${candidate.path}（$error）');
      }
    }

    throw DataRootUnavailable(
      '没有可写的数据目录：${failures.join('；')}。'
      '请检查目录权限，或用环境变量 MDIARY_HOME 指定一个可写目录。',
    );
  }

  /// 建目录并真写一次探针文件：只有真能写才算可用。
  static Future<void> prepare(String path) async {
    final dir = Directory(path);
    await dir.create(recursive: true);
    final probe = File(p.join(path, probeFileName));
    await probe.writeAsString('ok', flush: true);
    try {
      await probe.delete();
    } catch (_) {
      // 探针删不掉不影响可用性，只是个残留小文件。
    }
  }

  static String _platformKey() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  static String? _exeDirectoryOf(String? resolvedExecutable) {
    if (resolvedExecutable == null || resolvedExecutable.trim().isEmpty) {
      return null;
    }
    final name = p.basenameWithoutExtension(resolvedExecutable).toLowerCase();
    if (_testHosts.contains(name)) return null;
    return p.dirname(resolvedExecutable);
  }

  static String _platformBase(Map<String, String> env, String platformKey) {
    switch (platformKey) {
      case 'windows':
        return env['APPDATA'] ??
            p.join(env['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
      case 'macos':
        return p.join(env['HOME'] ?? '.', 'Library', 'Application Support');
      default:
        final xdg = env['XDG_DATA_HOME'];
        return (xdg != null && xdg.isNotEmpty)
            ? xdg
            : p.join(env['HOME'] ?? '.', '.local', 'share');
    }
  }
}

class _Candidate {
  const _Candidate(this.path, this.source);

  final String path;
  final DataRootSource source;
}
