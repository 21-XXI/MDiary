import 'dart:io';

import 'package:flutter/foundation.dart';

/// 崩溃与错误日志：写入 `%APPDATA%\MDiary\logs\error.log`。
///
/// 用户报「闪退/白屏」时，这个文件是唯一能拿到现场的东西。
/// 超过 1 MB 时轮转一份 `error.old.log`，避免无限增长。
class AppLogger {
  AppLogger(this.logFile);

  final File logFile;

  static const int maxBytes = 1024 * 1024;

  void log(String tag, Object error, [StackTrace? stack]) {
    try {
      final dir = logFile.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      if (logFile.existsSync() && logFile.lengthSync() > maxBytes) {
        final backup = File('${logFile.path}.old');
        if (backup.existsSync()) backup.deleteSync();
        logFile.renameSync(backup.path);
      }
      final buffer = StringBuffer()
        ..writeln('[${DateTime.now().toIso8601String()}] $tag')
        ..writeln(error);
      if (stack != null) buffer.writeln(stack);
      buffer.writeln('-' * 60);
      logFile.writeAsStringSync(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志本身失败不能影响主流程
    }
  }

  /// 安装全局钩子：Flutter 框架异常、平台未捕获异常。
  void install() {
    FlutterError.onError = (details) {
      log('FlutterError', details.exception, details.stack);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log('Uncaught', error, stack);
      return false;
    };
  }
}

/// 解析日志文件位置；[rootPath] 为空时退化到系统临时目录，保证能落盘。
File resolveLogFile(String rootPath) {
  final base = rootPath.trim().isEmpty
      ? Directory.systemTemp.path
      : '$rootPath${Platform.pathSeparator}logs';
  return File('$base${Platform.pathSeparator}error.log');
}
