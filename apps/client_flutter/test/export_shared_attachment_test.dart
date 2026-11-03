@TestOn('windows')
library;

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// 「一个附件可索引多个 .md」：库里只存一份；导出时每篇 .md 都要能引用到它，
/// 但整个导出目录里也只放一份（不重复占空间）。
void main() {
  final dll = _locateSqlite3();
  if (dll != null) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll));
  }
  final skip = dll == null;

  test('共用附件：库内一份、导出目录一份，每篇 .md 都带引用', () async {
    final temp = Directory.systemTemp.createTempSync('mdiary_share_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final entries = EntryRepository(db);
    final attachments = AttachmentRepository(db);
    final store = AttachmentStore(Directory(p.join(temp.path, 'attachments')));
    final io = MarkdownIo(
      entries: entries,
      attachments: attachments,
      store: store,
    );

    final first = entries.create(deviceId: 'd', date: DateTime(2026, 11, 1));
    final second = entries.create(deviceId: 'd', date: DateTime(2026, 11, 2));
    final blob = await store.storeBytes(
      Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      'shot.png',
    );
    final ref = '![](assets/${blob.sha256}${blob.ext})';
    for (final entry in <Entry>[first, second]) {
      attachments.insert(
        entryId: entry.id,
        sha256: blob.sha256,
        filename: 'shot.png',
        mime: 'image/png',
        sizeBytes: blob.sizeBytes,
      );
      entries.saveContent(entry.id, body: ref);
    }
    expect(attachments.referencedHashes(), <String>{blob.sha256});

    final out = Directory(p.join(temp.path, 'export'))..createSync();
    final result = await io.exportAll(out.path);

    expect(result.entries, 2);
    expect(result.attachments, 1, reason: '同 sha 只复制一次');

    final assets = Directory(p.join(out.path, 'assets'))
        .listSync()
        .whereType<File>()
        .toList();
    expect(assets, hasLength(1), reason: '导出目录里也只放一份');

    final markdownFiles = out
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.md'))
        .toList();
    expect(markdownFiles, hasLength(2));
    for (final file in markdownFiles) {
      expect(
        file.readAsStringSync(),
        contains('assets/${blob.sha256}${blob.ext}'),
        reason: '${p.basename(file.path)} 应引用到这个附件',
      );
    }
  }, skip: skip);
}

String? _locateSqlite3() {
  final fromEnv = Platform.environment['MDIARY_SQLITE_DLL'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  for (final candidate in <String>[
    'build/windows/x64/runner/Release/sqlite3.dll',
    'build/windows/x64/runner/Debug/sqlite3.dll',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}
