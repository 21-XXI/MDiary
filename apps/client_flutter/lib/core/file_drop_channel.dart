import 'package:flutter/services.dart';

/// 从资源管理器把文件拖进窗口（仅 Windows 桌面）。
///
/// runner 侧接收 `WM_DROPFILES`，把路径列表通过 `mdiary/drop` 通道的 `files` 方法送上来；
/// 其它平台没有这个通道，[install] 之后也不会有回调，不需要额外判断。
class FileDropChannel {
  FileDropChannel._();

  static const MethodChannel channel = MethodChannel('mdiary/drop');

  static void install(Future<void> Function(List<String> paths) onFiles) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'files') return null;
      final arguments = call.arguments;
      if (arguments is! List) return null;
      final paths = arguments.whereType<String>().toList(growable: false);
      if (paths.isNotEmpty) await onFiles(paths);
      return null;
    });
  }
}
