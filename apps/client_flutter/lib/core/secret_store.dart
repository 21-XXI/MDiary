import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// 本机密钥加密（Windows 用 DPAPI，绑定当前用户）。
///
/// 只用于存云端模型的 API Key：`settings.json` 里是密文（base64），换用户/换机器解不开。
/// 非 Windows 目前退化为 base64（并在 UI 上明确提示），后续可接 Keychain/libsecret。
class SecretStore {
  SecretStore._();

  static const String _prefix = 'dpapi:';
  static const String _plainPrefix = 'b64:';

  static const int _entropySeed = 0x4d444941; // "MDIA"

  /// 加密成可直接写进 JSON 的字符串。
  static String protect(String plain) {
    if (plain.isEmpty) return '';
    if (!Platform.isWindows) {
      return '$_plainPrefix${base64Url.encode(utf8.encode(plain))}';
    }
    try {
      final bytes = utf8.encode(plain);
      final output = _dpapi(bytes, protectMode: true);
      return '$_prefix${base64.encode(output)}';
    } on Object {
      // DPAPI 不可用时至少不要明文落盘
      return '$_plainPrefix${base64Url.encode(utf8.encode(plain))}';
    }
  }

  /// 解密；失败或格式不认识返回 null。
  static String? unprotect(String stored) {
    if (stored.isEmpty) return null;
    if (stored.startsWith(_plainPrefix)) {
      try {
        return utf8.decode(base64Url.decode(stored.substring(_plainPrefix.length)));
      } on Object {
        return null;
      }
    }
    if (!stored.startsWith(_prefix)) return null;
    if (!Platform.isWindows) return null;
    try {
      final bytes = base64.decode(stored.substring(_prefix.length));
      return utf8.decode(_dpapi(bytes, protectMode: false));
    } on Object {
      return null;
    }
  }

  static bool get isSecure => Platform.isWindows;

  /// 调用 CryptProtectData / CryptUnprotectData。
  static Uint8List _dpapi(List<int> input, {required bool protectMode}) {
    // CryptProtectData/CryptUnprotectData 在 crypt32.dll（不是 advapi32）。
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');

    final protect = crypt32.lookupFunction<
        Int32 Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_DataBlob>,
        ),
        int Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_DataBlob>,
        )>('CryptProtectData');
    final unprotect = crypt32.lookupFunction<
        Int32 Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_DataBlob>,
        ),
        int Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_DataBlob>,
        )>('CryptUnprotectData');
    final localFree = kernel32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('LocalFree');

    final inputPtr = calloc<Uint8>(input.length);
    inputPtr.asTypedList(input.length).setAll(0, input);
    final inputBlob = calloc<_DataBlob>()
      ..ref.cbData = input.length
      ..ref.pbData = inputPtr;

    final entropyPtr = calloc<Uint8>(4);
    entropyPtr.asTypedList(4).setAll(0, <int>[
      _entropySeed >> 24 & 0xff,
      _entropySeed >> 16 & 0xff,
      _entropySeed >> 8 & 0xff,
      _entropySeed & 0xff,
    ]);
    final entropyBlob = calloc<_DataBlob>()
      ..ref.cbData = 4
      ..ref.pbData = entropyPtr;

    final outBlob = calloc<_DataBlob>();
    try {
      final ok = protectMode
          ? protect(
              inputBlob,
              nullptr,
              entropyBlob,
              nullptr,
              nullptr,
              0x1, // CRYPTPROTECT_UI_FORBIDDEN
              outBlob,
            )
          : unprotect(
              inputBlob,
              nullptr,
              entropyBlob,
              nullptr,
              nullptr,
              0x1,
              outBlob,
            );
      if (ok == 0) {
        throw StateError('DPAPI 调用失败（${protectMode ? 'protect' : 'unprotect'}）');
      }
      final length = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(length));
    } finally {
      if (outBlob.ref.pbData != nullptr) localFree(outBlob.ref.pbData.cast());
      calloc.free(outBlob);
      calloc.free(entropyBlob);
      calloc.free(entropyPtr);
      calloc.free(inputBlob);
      calloc.free(inputPtr);
    }
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}
