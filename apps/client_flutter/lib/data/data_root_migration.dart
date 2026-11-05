import 'dart:io';

import 'package:path/path.dart' as p;

/// 一次数据目录迁移的结果。
class MigrationResult {
  const MigrationResult({
    required this.target,
    required this.files,
    required this.bytes,
  });

  final String target;
  final int files;
  final int bytes;
}

/// 迁移失败（目标不可用、校验不一致等），消息直接面向用户。
class DataRootMigrationException implements Exception {
  const DataRootMigrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把整个数据根目录搬到另一个目录：数据库 + 附件 + 日志 + settings.json。
///
/// 只复制、不移动：调用方确认新库能打开、位置也记住了之后，才用
/// [removeOldRoot] 删旧目录，任何一步失败旧数据都还在。
class DataRootMigration {
  DataRootMigration({required this.source, required this.target});

  final String source;
  final String target;

  static const String databaseName = 'mdiary.sqlite';

  /// 数据库子目录（v1.1 起数据库单独放 `db/`）。
  static const String databaseDir = 'db';

  static String databaseFileIn(String root) =>
      p.join(root, databaseDir, databaseName);

  /// 本程序自己管理的顶层名字；删旧目录时也只动这些。
  static const List<String> managedNames = <String>[
    databaseDir,
    databaseName,
    'mdiary.sqlite-wal',
    'mdiary.sqlite-shm',
    'attachments',
    'logs',
    'settings.json',
  ];

  /// 目标目录不可用的原因；可用时返回 null。不会创建或修改任何文件。
  static String? blockingReason(String target) {
    if (File(databaseFileIn(target)).existsSync()) {
      return '目标目录里已经有 MDiary 数据（$databaseDir/$databaseName），请换一个空文件夹';
    }
    final dir = Directory(target);
    if (!dir.existsSync()) return null;
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (error) {
      return '无法读取目标目录：$error';
    }
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (name.toLowerCase() == databaseName) {
        return '目标目录里已经有 MDiary 数据（$databaseName），请换一个空文件夹';
      }
      if (!managedNames.contains(name)) {
        return '目标目录不是空目录（发现「$name」），请换一个空文件夹或新建一个';
      }
    }
    return null;
  }

  /// 只做校验，不落盘。迁移前先调用，避免把库关了才发现目标不可用。
  Future<void> validate() async {
    final src = p.canonicalize(source);
    final dst = p.canonicalize(target);
    if (p.equals(src, dst)) {
      throw const DataRootMigrationException('目标目录与当前数据目录是同一个');
    }
    if (p.isWithin(src, dst)) {
      throw const DataRootMigrationException('目标目录不能放在当前数据目录里面');
    }
    if (p.isWithin(dst, src)) {
      throw const DataRootMigrationException('目标目录不能是当前数据目录的上级目录');
    }
    if (!Directory(src).existsSync()) {
      throw DataRootMigrationException('当前数据目录不存在：$src');
    }
    if (!File(databaseFileIn(src)).existsSync() &&
        !File(p.join(src, databaseName)).existsSync()) {
      throw DataRootMigrationException('当前数据目录里没有 $databaseName：$src');
    }
    final blocked = blockingReason(dst);
    if (blocked != null) throw DataRootMigrationException(blocked);
  }

  /// 复制并逐文件校验大小。调用前必须先关掉数据库连接。
  Future<MigrationResult> run() async {
    await validate();
    final src = p.canonicalize(source);
    final dst = p.canonicalize(target);
    final targetDir = Directory(dst);
    await targetDir.create(recursive: true);

    var files = 0;
    var bytes = 0;

    Future<void> copyFile(File file, {String? toRelative}) async {
      final relative = toRelative ?? p.relative(file.path, from: src);
      final out = File(p.join(dst, relative));
      await out.parent.create(recursive: true);
      await file.copy(out.path);
      final sourceLength = await file.length();
      final targetLength = await out.length();
      if (sourceLength != targetLength) {
        throw DataRootMigrationException(
          '复制校验失败：$relative（源 $sourceLength 字节，目标 $targetLength 字节）',
        );
      }
      files++;
      bytes += sourceLength;
    }

    // 数据库必须在最前面：它是「迁移成功」的必要条件，附件缺失只影响预览。
    final dbDir = Directory(p.join(src, databaseDir));
    if (dbDir.existsSync()) {
      for (final file in dbDir.listSync(recursive: true).whereType<File>()) {
        await copyFile(file);
      }
    } else {
      // 老布局：库直接在根目录，搬过去时落到 db/ 下。
      await copyFile(
        File(p.join(src, databaseName)),
        toRelative: p.join(databaseDir, databaseName),
      );
    }

    final attachments = Directory(p.join(src, 'attachments'));
    if (attachments.existsSync()) {
      for (final file in attachments.listSync(recursive: true).whereType<File>()) {
        await copyFile(file);
      }
    }

    final settings = File(p.join(src, 'settings.json'));
    if (settings.existsSync()) await copyFile(settings);

    // 日志只是诊断材料，搬不过去不影响使用。
    final logs = Directory(p.join(src, 'logs'));
    if (logs.existsSync()) {
      for (final file in logs.listSync(recursive: true).whereType<File>()) {
        try {
          await copyFile(file);
        } on Object {
          // 日志可能正被别的实例占用，跳过。
        }
      }
    }

    return MigrationResult(target: dst, files: files, bytes: bytes);
  }

  /// 迁移成功后删掉旧目录。只删 [managedNames]，目录空了才删目录本身。
  ///
  /// 旧目录里装着 exe（便携版把数据放 exe 同目录的情况）时一律不动。
  /// 返回实际删掉的名字；失败不抛异常（新位置已经可用，旧文件残留交给用户处理）。
  static Future<List<String>> removeOldRoot(
    String path, {
    required String? exePath,
  }) async {
    final removed = <String>[];
    final dir = Directory(p.canonicalize(path));
    if (!dir.existsSync()) return removed;
    if (exePath != null && exePath.trim().isNotEmpty) {
      final exe = p.canonicalize(exePath);
      if (p.isWithin(dir.path, exe)) return removed;
    }

    for (final name in managedNames) {
      final entityPath = p.join(dir.path, name);
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final type = FileSystemEntity.typeSync(entityPath, followLinks: false);
          if (type == FileSystemEntityType.notFound) break;
          final FileSystemEntity entity =
              type == FileSystemEntityType.directory
              ? Directory(entityPath)
              : File(entityPath);
          await entity.delete(recursive: true);
          removed.add(name);
          break;
        } on Object {
          // 句柄还没释放（杀毒 / 索引服务）时稍等再试。
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
    }

    try {
      if (await dir.list().isEmpty) {
        await dir.delete(recursive: true);
        removed.add('.');
      }
    } on Object {
      // 目录删不掉就留着，反正是空的。
    }
    return removed;
  }
}
