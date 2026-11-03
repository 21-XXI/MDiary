import 'dart:io';

import 'package:flutter/services.dart';

/// 读取剪贴板里的图片（仅 Windows；runner 侧用 GDI+ 编码成 PNG）。
///
/// 读不到（没有图片 / 非 Windows / 通道不存在）都返回 null，
/// 调用方只需要处理「拿到 bytes」和「null」两种情况。
typedef ClipboardImageReader = Future<Uint8List?> Function();

class ClipboardImage {
  ClipboardImage._();

  static const MethodChannel channel = MethodChannel('mdiary/clipboard');

  static Future<Uint8List?> read() async {
    if (!Platform.isWindows) return null;
    try {
      final bytes = await channel.invokeMethod<Uint8List>('readImagePng');
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
