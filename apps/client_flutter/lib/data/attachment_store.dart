import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'attachment_repository.dart';

class AttachmentTooLargeException implements Exception {
  AttachmentTooLargeException(this.sizeBytes, this.limitBytes);

  final int sizeBytes;
  final int limitBytes;

  @override
  String toString() =>
      '附件过大：${sizeBytes ~/ (1024 * 1024)} MB，上限 ${limitBytes ~/ (1024 * 1024)} MB';
}

/// 内容寻址附件库。
///
/// v2 起**字节存进数据库**（`attachment_blobs`，按 sha256 去重），磁盘上的
/// `attachments/<sha 前两位>/<sha><ext>` 退化为「缓存」：给预览和
/// 「用系统默认程序打开」用，删掉也能从库里自动重建。
///
/// [blobs] 为 null 时是纯文件模式（老单元测试用），行为与 v1 一致。
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
  AttachmentStore(this.directory, {this.blobs, int? maxFileBytes})
    : maxFileBytes = maxFileBytes ?? defaultMaxBytes;

  /// 缓存目录（`<数据目录>/attachments`）。
  final Directory directory;

  /// 数据库里的附件字节；null 表示纯文件模式（测试 / 老数据）。
  final AttachmentRepository? blobs;

  /// 单文件上限。v2 起提高到 100 MB（字节在库里，不再受文件系统零散大文件困扰）。
  final int maxFileBytes;

  static const int defaultMaxBytes = 100 * 1024 * 1024;

  /// 兼容旧代码的常量名。
  static const int maxFileBytesLegacy = defaultMaxBytes;

  Future<StoredBlob> storeBytes(Uint8List bytes, String filename) async {
    if (bytes.length > maxFileBytes) {
      throw AttachmentTooLargeException(bytes.length, maxFileBytes);
    }
    final digest = sha256.convert(bytes).toString();
    final ext = normalizeExtension(filename);
    // 数据库是源：先写库，再落一份缓存给预览/打开用。
    blobs?.putBlob(digest, bytes);
    final file = File(p.join(directory.path, digest.substring(0, 2), '$digest$ext'));
    await file.parent.create(recursive: true);
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

  /// 从磁盘读一个附件入库。
  ///
  /// 分块算 sha256（不把整个文件读两次）；如果库里已经有这份字节，直接写缓存
  /// 返回，**完全不读文件内容**——重复导入大文件不会有内存峰值。
  Future<StoredBlob> storeFile(String sourcePath) async {
    final file = File(sourcePath);
    final length = await file.length();
    if (length > maxFileBytes) {
      throw AttachmentTooLargeException(length, maxFileBytes);
    }
    final digest = await _sha256OfFile(file);
    final ext = normalizeExtension(file.path);
    final cache = File(
      p.join(directory.path, digest.substring(0, 2), '$digest$ext'),
    );

    if (blobs?.hasBlob(digest) ?? false) {
      await cache.parent.create(recursive: true);
      if (!await cache.exists()) await file.copy(cache.path);
      return StoredBlob(
        sha256: digest,
        ext: ext,
        sizeBytes: length,
        path: cache.path,
        filename: p.basename(file.path),
      );
    }

    final bytes = await file.readAsBytes();
    return storeBytes(bytes, p.basename(file.path));
  }

  static Future<String> _sha256OfFile(File file) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  /// 缓存目录当前占用的字节数（不含子目录本身）。
  Future<int> cacheBytes() async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } on Object {
        // 文件刚被删掉：忽略
      }
    }
    return total;
  }

  /// 清空缓存目录（字节都在数据库里，下次预览/打开会自动重建）。返回释放的字节数。
  Future<int> clearCache() async {
    final freed = await cacheBytes();
    if (!await directory.exists()) return 0;
    await for (final entity in directory.list(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } on Object {
        // 被占用就跳过，不影响其它文件
      }
    }
    return freed;
  }

  /// 命中则返回本地绝对路径（预览与打开附件用）。
  ///
  /// 缓存文件不在时会从数据库里重建 —— 所以即使用户手删了 `attachments/`，
  /// 附件依然能打开。
  String? pathFor(String sha256, String ext) {
    final file = File(
      p.join(directory.path, sha256.substring(0, 2), '$sha256$ext'),
    );
    if (file.existsSync()) return file.path;
    final bytes = blobs?.readBlob(sha256);
    if (bytes == null) return null;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    } on Object {
      return null;
    }
    return file.path;
  }

  /// 把老版本留在磁盘上的附件搬进数据库（幂等）。返回搬入的份数。
  Future<int> backfillFromFiles() async {
    final repository = blobs;
    if (repository == null) return 0;
    final missing = repository.shasWithoutBlob();
    var imported = 0;
    for (final sha256 in missing) {
      final ext = repository.extensionOf(sha256);
      final file = File(
        p.join(directory.path, sha256.substring(0, 2), '$sha256$ext'),
      );
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) continue;
      repository.putBlob(sha256, bytes);
      imported++;
    }
    return imported;
  }

  Future<Set<String>> hashesOnDisk() async {
    final result = <String>{};
    if (!await directory.exists()) return result;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      result.add(p.basenameWithoutExtension(entity.path));
    }
    return result;
  }

  /// 回收孤儿附件：库里的字节 + 磁盘缓存都清掉；返回清理条数。
  Future<int> collectGarbage(Set<String> referenced) async {
    var removed = blobs?.deleteUnreferencedBlobs() ?? 0;
    if (!await directory.exists()) return removed;
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
  '.docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.mp3': 'audio/mpeg',
  '.mp4': 'video/mp4',
};

String mimeForFilename(String filename) =>
    _mimeByExtension[normalizeExtension(filename)] ??
    'application/octet-stream';

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

/// 收集 [sha256.startChunkedConversion] 的摘要。
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('分块摘要没有结果'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}