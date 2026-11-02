import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class AttachmentTooLargeException implements Exception {
  AttachmentTooLargeException(this.sizeBytes, this.limitBytes);

  final int sizeBytes;
  final int limitBytes;

  @override
  String toString() => '附件过大：${sizeBytes ~/ (1024 * 1024)} MB，上限 ${limitBytes ~/ (1024 * 1024)} MB';
}

/// 内容寻址附件库：`<root>/<sha前两位>/<sha><ext>`。
///
/// 同一内容只落一份（天然去重、便于 v2.0 按哈希上传）。
class StoredBlob {
  const StoredBlob({
    required this.sha256,
    required this.ext,
    required this.sizeBytes,
    required this.path,
    required this.filename,
  });

  final String sha256;
  final String ext;
  final int sizeBytes;
  final String path;
  final String filename;

  /// 正文中的相对引用：`assets/<sha>.<ext>`
  String get relativeRef => 'assets/$sha256$ext';
}

class AttachmentStore {
  AttachmentStore(this.directory);

  final Directory directory;

  /// project.md 4.1：单文件 ≤ 25 MB
  static const int maxFileBytes = 25 * 1024 * 1024;

  Future<StoredBlob> storeBytes(Uint8List bytes, String filename) async {
    if (bytes.length > maxFileBytes) {
      throw AttachmentTooLargeException(bytes.length, maxFileBytes);
    }
    final digest = sha256.convert(bytes).toString();
    final ext = normalizeExtension(filename);
    final folder = Directory(p.join(directory.path, digest.substring(0, 2)));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, '$digest$ext'));
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return StoredBlob(
      sha256: digest,
      ext: ext,
      sizeBytes: bytes.length,
      path: file.path,
      filename: filename,
    );
  }

  Future<StoredBlob> storeFile(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    return storeBytes(bytes, p.basename(sourcePath));
  }

  /// 命中则返回本地绝对路径（预览与打开附件用）。
  String? pathFor(String sha256, String ext) {
    final file = File(p.join(directory.path, sha256.substring(0, 2), '$sha256$ext'));
    return file.existsSync() ? file.path : null;
  }

  Future<Set<String>> hashesOnDisk() async {
    final result = <String>{};
    if (!await directory.exists()) return result;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      result.add(p.basenameWithoutExtension(entity.path));
    }
    return result;
  }

  /// 删除未被任何条目引用的附件文件；返回删除数量。
  Future<int> collectGarbage(Set<String> referenced) async {
    if (!await directory.exists()) return 0;
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      await for (final child in entity.list(followLinks: false)) {
        if (child is! File) continue;
        final hash = p.basenameWithoutExtension(child.path);
        if (referenced.contains(hash)) continue;
        await child.delete();
        removed++;
      }
      if (await entity.list().isEmpty) {
        await entity.delete();
      }
    }
    return removed;
  }
}

/// 白名单式扩展名归一化：仅保留简单字母数字扩展名，其余按无扩展名处理。
String normalizeExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 || dot == filename.length - 1) return '';
  final ext = filename.substring(dot + 1).toLowerCase();
  if (ext.length > 8) return '';
  if (!RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return '';
  return '.$ext';
}

const Map<String, String> _mimeByExtension = <String, String>{
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.svg': 'image/svg+xml',
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.zip': 'application/zip',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.mp3': 'audio/mpeg',
  '.mp4': 'video/mp4',
};

String mimeForFilename(String filename) =>
    _mimeByExtension[normalizeExtension(filename)] ?? 'application/octet-stream';

bool isImageFileName(String filename) {
  final ext = normalizeExtension(filename);
  return ext == '.png' ||
      ext == '.jpg' ||
      ext == '.jpeg' ||
      ext == '.gif' ||
      ext == '.webp' ||
      ext == '.bmp' ||
      ext == '.svg';
}
