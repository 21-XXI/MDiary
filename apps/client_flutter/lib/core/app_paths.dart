import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用数据目录解析。
///
/// v1.0 只依赖 dart:io（不引入 path_provider 插件），以便：
/// 1. 少一个平台插件 -> 首次编译失败面更小；
/// 2. 单测可以直接换目录（MDIARY_HOME 环境变量）。
class AppPaths {
  AppPaths._();

  static late final Directory root;
  static bool _initialized = false;

  /// 可用环境变量 MDIARY_HOME 覆盖数据根目录（测试与便携模式用）。
  static Future<void> init() async {
    if (_initialized) return;
    final override = Platform.environment['MDIARY_HOME'];
    final String base;
    if (override != null && override.trim().isNotEmpty) {
      base = override;
    } else if (Platform.isWindows) {
      base =
          Platform.environment['APPDATA'] ??
          p.join(
            Platform.environment['USERPROFILE'] ?? '.',
            'AppData',
            'Roaming',
          );
    } else if (Platform.isMacOS) {
      base = p.join(
        Platform.environment['HOME'] ?? '.',
        'Library',
        'Application Support',
      );
    } else {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      base = (xdg != null && xdg.isNotEmpty)
          ? xdg
          : p.join(Platform.environment['HOME'] ?? '.', '.local', 'share');
    }
    root = Directory(p.join(base, 'MDiary'));
    await root.create(recursive: true);
    _initialized = true;
  }

  static String get databaseFile => p.join(root.path, 'mdiary.sqlite');

  static String get attachmentsPath => p.join(root.path, 'attachments');

  static Directory get attachmentsDir => Directory(attachmentsPath);

  static String get logsPath => p.join(root.path, 'logs');

  static String get settingsFile => p.join(root.path, 'settings.json');
}
