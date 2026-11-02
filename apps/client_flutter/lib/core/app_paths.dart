import 'dart:io';

import 'package:path/path.dart' as p;

/// 数据根目录的来源，决定设置页要不要提示「数据没放在默认位置」。
enum DataRootSource {
  /// `MDIARY_HOME` 环境变量（测试 / 便携模式，用户显式指定）。
  envOverride,

  /// 平台默认位置（Windows 为 `%APPDATA%\MDiary`）。
  platformDefault,

  /// 默认位置不可写时，退到程序所在目录旁的 `MDiaryData`。
  portableFallback,

  /// 再不可写时，退到系统临时目录（重启后可能被清理）。
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

  /// 仅在发生回退时非空：原计划使用的目录 + 失败原因。
  final String? fallbackReason;

  bool get isFallback =>
      source == DataRootSource.portableFallback ||
      source == DataRootSource.tempFallback;
}

/// 所有候选目录都不可用时抛出，消息直接面向用户。
class DataRootUnavailable implements Exception {
  const DataRootUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 应用数据目录解析。
///
/// v1.0 只依赖 dart:io（不引入 path_provider 插件），以便：
/// 1. 少一个平台插件 -> 首次编译失败面更小；
/// 2. 单测可以直接换目录（MDIARY_HOME 环境变量）。
///
/// 原则：**能启动比「待在该在的地方」更重要**。
/// `%APPDATA%` 在受限进程（沙箱 / 低完整性令牌 / 漫游配置被重定向）里可能只给读权限，
/// 此时直接 `create` 会抛 `PathAccessException(OS Error: 5)` 让应用白屏。
/// 因此按「显式指定 -> 平台默认 -> 程序旁 MDiaryData -> 系统临时目录」依次探测，
/// 找到第一个真的能写的目录；只有全部不可写才报错，并提示用 MDIARY_HOME 指定。
class AppPaths {
  AppPaths._();

  static const String dataDirName = 'MDiary';
  static const String portableDirName = 'MDiaryData';
  static const String probeFileName = '.write_probe';

  static late final Directory root;
  static DataRoot? _resolution;
  static bool _initialized = false;

  /// 没有稳定「程序目录」的宿主进程（单测 / dart run），不能拿它做便携回退。
  static const List<String> _testHosts = <String>['flutter_tester', 'dart', 'flutter'];

  /// 可用环境变量 MDIARY_HOME 覆盖数据根目录（测试与便携模式用）。
  static Future<void> init() async {
    if (_initialized) return;
    final resolved = await resolve(
      env: Platform.environment,
      platformKey: _platformKey(),
      resolvedExecutable: Platform.resolvedExecutable,
      tempDir: Directory.systemTemp.path,
    );
    root = Directory(resolved.path);
    _resolution = resolved;
    _initialized = true;
  }

  /// 当前的解析结果（未 init 时为 null）。
  static DataRoot? get resolution => _resolution;

  /// 是否退到了默认位置以外的目录。
  static bool get isFallback => _resolution?.isFallback ?? false;

  /// 回退原因；未回退时为 null。
  static String? get fallbackReason => _resolution?.fallbackReason;

  static String get databaseFile => p.join(root.path, 'mdiary.sqlite');

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
    Future<void> Function(String path)? prepare,
  }) async {
    final preparePath = prepare ?? _prepare;
    final override = (env['MDIARY_HOME'] ?? '').trim();
    final candidates = <_Candidate>[];

    if (override.isNotEmpty) {
      // 用户显式指定就只认它：不静默换目录，否则数据会跑到意想不到的地方。
      candidates.add(
        _Candidate(
          p.join(override, dataDirName),
          DataRootSource.envOverride,
        ),
      );
    } else {
      candidates.add(
        _Candidate(
          p.join(_platformBase(env, platformKey), dataDirName),
          DataRootSource.platformDefault,
        ),
      );
      final portableBase = _portableBase(resolvedExecutable);
      if (portableBase != null) {
        candidates.add(
          _Candidate(
            p.join(portableBase, portableDirName),
            DataRootSource.portableFallback,
          ),
        );
      }
      candidates.add(
        _Candidate(
          p.join(tempDir, dataDirName),
          DataRootSource.tempFallback,
        ),
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

  /// 建目录并真写一次探针文件：`create` 对已存在的只读目录不会报错，
  /// 只靠它会把问题推迟到打开数据库时才暴露。
  static Future<void> _prepare(String path) async {
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

  static String _platformBase(Map<String, String> env, String platformKey) {
    switch (platformKey) {
      case 'windows':
        return env['APPDATA'] ??
            p.join(env['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
      case 'macos':
        return p.join(
          env['HOME'] ?? '.',
          'Library',
          'Application Support',
        );
      default:
        final xdg = env['XDG_DATA_HOME'];
        return (xdg != null && xdg.isNotEmpty)
            ? xdg
            : p.join(env['HOME'] ?? '.', '.local', 'share');
    }
  }

  /// 便携目录用「可执行文件同级」；在 flutter_tester / dart 宿主里没有稳定的
  /// 程序目录，跳过这一级，免得测试把数据写进 SDK。
  static String? _portableBase(String? resolvedExecutable) {
    if (resolvedExecutable == null || resolvedExecutable.trim().isEmpty) {
      return null;
    }
    final name = p.basenameWithoutExtension(resolvedExecutable).toLowerCase();
    if (_testHosts.contains(name)) return null;
    return p.dirname(resolvedExecutable);
  }
}

class _Candidate {
  const _Candidate(this.path, this.source);

  final String path;
  final DataRootSource source;
}
