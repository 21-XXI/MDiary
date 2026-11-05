import 'dart:io';

import 'package:path/path.dart' as p;

import 'attachment_repository.dart';
import 'attachment_store.dart';
import 'entry_repository.dart';
import 'markdown_document.dart';
import 'models.dart';
import 'tag_repository.dart';

class ExportResult {
  ExportResult({
    required this.directory,
    required this.entries,
    required this.attachments,
    required this.files,
  });

  final String directory;
  final int entries;
  final int attachments;
  final List<String> files;
}

class ImportResult {
  ImportResult({
    required this.imported,
    required this.skipped,
    required this.errors,
  });

  final int imported;
  final int skipped;
  final List<String> errors;
}

/// .md 导入 / 导出。导出必须可被 Typora / VS Code 直接渲染，
/// 所以附件复制到 `assets/`，正文相对路径保持不变。
class MarkdownIo {
  MarkdownIo({
    required this.entries,
    required this.attachments,
    required this.store,
    this.tags,
  });

  final EntryRepository entries;
  final AttachmentRepository attachments;
  final AttachmentStore store;

  /// 标签仓储；为 null 时导出不写 tags、导入不落标签（老调用方兼容）。
  final TagRepository? tags;

  /// 导出单篇到 [targetDir]，返回写出的 .md 路径。
  Future<String> exportEntry(Entry entry, String targetDir) async {
    final dir = Directory(targetDir);
    await dir.create(recursive: true);
    await _copyAttachments(entry, dir);
    final content = buildMarkdownDocument(
      title: entry.title.trim().isEmpty ? '无标题' : entry.title.trim(),
      date: entry.entryDate,
      tags: tags?.tagsOf(entry.id) ?? const <String>[],
      body: entry.bodyMd,
    );
    final target = _uniquePath(dir, safeFileName(entry.entryDate, entry.title));
    final file = File(target);
    await _writeAtomic(file, content);
    return file.path;
  }

  /// 整库导出：所有未删除条目 + assets/。
  Future<ExportResult> exportAll(String targetDir) async {
    final dir = Directory(targetDir);
    await dir.create(recursive: true);
    final all = entries.query();
    final files = <String>[];
    var attachmentCount = 0;
    for (final entry in all) {
      attachmentCount += await _copyAttachments(entry, dir);
      final content = buildMarkdownDocument(
        title: entry.title.trim().isEmpty ? '无标题' : entry.title.trim(),
        date: entry.entryDate,
        tags: tags?.tagsOf(entry.id) ?? const <String>[],
        body: entry.bodyMd,
      );
      final target = _uniquePath(
        dir,
        safeFileName(entry.entryDate, entry.title),
      );
      final file = File(target);
      await _writeAtomic(file, content);
      files.add(file.path);
    }
    return ExportResult(
      directory: dir.path,
      entries: all.length,
      attachments: attachmentCount,
      files: files,
    );
  }

  Future<int> _copyAttachments(Entry entry, Directory dir) async {
    final list = attachments.listByEntry(entry.id);
    if (list.isEmpty) return 0;
    final assetsDir = Directory(p.join(dir.path, 'assets'));
    await assetsDir.create(recursive: true);
    var copied = 0;
    for (final attachment in list) {
      final ext = normalizeExtension(attachment.filename);
      final target = File(p.join(assetsDir.path, '${attachment.sha256}$ext'));
      if (await target.exists()) continue;
      // 附件字节在库里（v2）；老数据还没有 blob 时回落到磁盘缓存。
      final bytes = attachments.readBlob(attachment.sha256);
      if (bytes != null) {
        await target.writeAsBytes(bytes, flush: true);
        copied++;
        continue;
      }
      final source = store.pathFor(attachment.sha256, ext);
      if (source == null) continue;
      await File(source).copy(target.path);
      copied++;
    }
    return copied;
  }

  /// 从目录递归导入 `.md`。已存在相同正文 + 同日期的条目会跳过（重复导入不产生副本）。
  Future<ImportResult> importDirectory(
    String sourceDir, {
    required String deviceId,
  }) async {
    final root = Directory(sourceDir);
    if (!await root.exists()) {
      return ImportResult(
        imported: 0,
        skipped: 0,
        errors: <String>['目录不存在：$sourceDir'],
      );
    }
    final errors = <String>[];
    var imported = 0;
    var skipped = 0;

    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      try {
        final stat = await file.stat();
        final content = await file.readAsString();
        final doc = parseMarkdownDocument(content, debugName: file.path);
        // 与导出侧保持一致：尾部空行不影响内容判定，否则「导出再导入」会被当成新条目
        final body = doc.body.trimRight();
        final date = doc.date ?? stat.modified;
        if (entries.existsSameContent(body, date)) {
          skipped++;
          continue;
        }
        final fallbackTitle = p.basenameWithoutExtension(file.path);
        final entry = entries.create(
          deviceId: deviceId,
          date: date,
          title: doc.title ?? fallbackTitle,
          body: body,
        );
        if (doc.tags.isNotEmpty) tags?.setTags(entry.id, doc.tags);

        final storedRefs = <String, StoredBlob>{};
        for (final rawRef in extractLocalReferences(body)) {
          final relative = _decodeRef(rawRef);
          final resolved = p.normalize(p.join(file.parent.path, relative));
          // 只允许导入目录内的文件：`../../x.png`、`C:\Windows\...` 这类目录外引用
          // 一律不复制（否则「导入一个文件夹」会悄悄读走别处文件）
          if (!_isInsideImportRoot(root, resolved)) continue;
          final candidate = File(resolved);
          if (!await candidate.exists()) continue;
          try {
            storedRefs[rawRef] = await store.storeFile(candidate.path);
          } on AttachmentTooLargeException catch (error) {
            errors.add('${p.basename(file.path)}: ${error.toString()}');
          }
        }

        if (storedRefs.isNotEmpty) {
          final rewritten = rewriteLocalReferences(body, (ref) {
            final blob = storedRefs[ref];
            if (blob == null) return null;
            return '${blob.sha256}${blob.ext}';
          });
          entries.saveContent(entry.id, body: rewritten);
          final seen = <String>{};
          for (final blob in storedRefs.values) {
            if (!seen.add(blob.sha256)) continue;
            attachments.insert(
              entryId: entry.id,
              sha256: blob.sha256,
              filename: blob.filename,
              mime: mimeForFilename(blob.filename),
              sizeBytes: blob.sizeBytes,
            );
          }
        }
        imported++;
      } catch (error) {
        errors.add('${p.basename(file.path)}: $error');
      }
    }
    return ImportResult(imported: imported, skipped: skipped, errors: errors);
  }

  /// 原子写：先写 `.tmp` 再改名，避免导出中途崩溃留下半截 .md。
  static Future<void> _writeAtomic(File file, String content) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  static String _decodeRef(String rawRef) {    var value = rawRef;
    if (value.startsWith('<') && value.endsWith('>')) {
      value = value.substring(1, value.length - 1);
    }
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }

  /// 引用是否落在导入目录内。用于拦截 `../../x.png`、绝对路径等目录外读取。
  static bool _isInsideImportRoot(Directory root, String resolvedPath) {
    final rootPath = p.normalize(root.absolute.path);
    final candidate = p.normalize(p.absolute(resolvedPath));
    if (p.equals(rootPath, candidate)) return true;
    return p.isWithin(rootPath, candidate);
  }

  static String _uniquePath(Directory dir, String fileName) {
    final candidate = File(p.join(dir.path, fileName));
    if (!candidate.existsSync()) return candidate.path;
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    for (var i = 2; i < 1000; i++) {
      final next = File(p.join(dir.path, '$base ($i)$ext'));
      if (!next.existsSync()) return next.path;
    }
    return p.join(
      dir.path,
      '$base-${DateTime.now().millisecondsSinceEpoch}$ext',
    );
  }
}
