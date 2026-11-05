import 'dart:io';

import 'package:flutter/services.dart';

/// 用系统默认程序打开文件 / 目录 / URL。
///
/// Windows 走 runner 的 `ShellExecuteW`（`mdiary/shell` 通道）：路径不经过
/// `cmd.exe` 解析，用户名或附件名里带空格、引号、`&` 都不会出问题；
/// 其它平台（或通道不存在时）回落到 `open` / `xdg-open`。
class SystemOpen {
  SystemOpen._();

  static const MethodChannel channel = MethodChannel('mdiary/shell');

  static Future<bool> open(String path) async {
    if (Platform.isWindows) {
      try {
        final opened = await channel.invokeMethod<bool>('open', path);
        if (opened == true) return true;
      } on MissingPluginException {
        // 测试环境 / 老 runner：回落到命令行
      } on PlatformException {
        // 同上
      }
    }
    try {
      if (Platform.isWindows) {
        await Process.start('rundll32', <String>[
          'url.dll,FileProtocolHandler',
          path,
        ], runInShell: false);
      } else if (Platform.isMacOS) {
        await Process.start('open', <String>[path]);
      } else {
        await Process.start('xdg-open', <String>[path]);
      }
      return true;
    } on Object {
      return false;
    }
  }
}
