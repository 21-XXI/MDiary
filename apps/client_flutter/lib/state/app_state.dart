import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/clipboard_image.dart';
import '../core/ids.dart';
import '../data/attachment_repository.dart';
import '../data/attachment_store.dart';
import '../data/data_root_migration.dart';
import '../data/database.dart';
import '../data/entry_repository.dart';
import '../data/markdown_io.dart';
import '../data/meta_repository.dart';
import '../data/models.dart';
import '../data/tag_repository.dart';

enum SaveStatus { idle, dirty, saving, saved, error }

/// 一次「导入数据库」的结果。
class DatabaseImportResult {
  const DatabaseImportResult({
    required this.source,
    required this.backup,
    required this.entries,
  });

  /// 被导入的库文件路径。
  final String source;

  /// 覆盖前自动备份的旧库路径。
  final String backup;

  /// 导入后库里的日记篇数。
  final int entries;
}

/// 新建附件完成后返回给编辑器插入 Markdown 链接。
class AttachedFile {
  const AttachedFile({
    required this.attachment,
    required this.blob,
    required this.isImage,
  });

  final Attachment attachment;
  final StoredBlob blob;
  final bool isImage;

  /// 写进正文的引用：**文件名始终写在 Markdown 里**（图片用 alt 文本），
  /// 这样导出的 .md 纯文本也能看出附件叫什么；预览里再把它渲染成彩色可点标签。
  String get markdownLink => isImage
      ? '![${_label(attachment.filename)}](assets/${blob.sha256}${blob.ext})'
      : '[${_label(attachment.filename)}](assets/${blob.sha256}${blob.ext})';

  /// 文件名里的 `[`/`]` 会破坏 Markdown 链接语法，按 CommonMark 的转义写。
  static String _label(String filename) => filename
      .replaceAll('\\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ');
}

/// 一次文件选择的产物（与 file_picker 解耦，便于测试注入）。
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

typedef SingleFilePicker = Future<PickedFile?> Function();
typedef DirectoryPicker = Future<String?> Function(String title);

/// 全局应用状态：唯一的数据入口 + 自动保存调度。
///
/// 刻意不用状态管理框架：单窗口、单用户，ChangeNotifier + InheritedNotifier
/// 足够，且少一个依赖就少一类版本兼容问题。
class AppState extends ChangeNotifier {
  AppState({
    required this.db,
    required this.entryRepo,
    required this.attachmentRepo,
    required this.metaRepo,
    required this.store,
    required this.markdownIo,
    SingleFilePicker? filePicker,
    DirectoryPicker? directoryPicker,
    this.dataRootPath = '',
    this.dataRootNotice,
    TagRepository? tagRepository,
    ClipboardImageReader? clipboardImageReader,
  }) : _filePicker = filePicker ?? _defaultFilePicker,
       _directoryPicker = directoryPicker ?? _defaultDirectoryPicker,
       _clipboardImageReader = clipboardImageReader ?? ClipboardImage.read,
       tagRepo = tagRepository ?? TagRepository(db);

  AppDatabase db;
  EntryRepository entryRepo;
  AttachmentRepository attachmentRepo;
  MetaRepository metaRepo;
  TagRepository tagRepo;
  AttachmentStore store;
  MarkdownIo markdownIo;

  final SingleFilePicker _filePicker;
  final DirectoryPicker _directoryPicker;
  final ClipboardImageReader _clipboardImageReader;

  /// 数据根目录（设置页展示/打开用）。由 main 注入，UI 不直接依赖全局 AppPaths。
  String dataRootPath;

  /// 默认数据目录不可写、退回备用目录时的说明；正常启动为 null。
  String? dataRootNotice;

  static Future<PickedFile?> _defaultFilePicker() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    return PickedFile(name: file.name, bytes: await file.readAsBytes());
  }

  static Future<String?> _defaultDirectoryPicker(String title) =>
      FilePicker.getDirectoryPath();

  static const Duration autosaveDebounce = Duration(milliseconds: 800);

  String deviceId = '';

  final List<Entry> _entries = <Entry>[];
  Entry? _selected;
  SaveStatus _status = SaveStatus.idle;
  String? _lastError;
  String _query = '';
  bool _loading = true;
  bool _dirtyDraft = false;
  int _trashCount = 0;
  Map<String, int> _attachmentCounts = const <String, int>{};
  Map<String, List<String>> _tagsByEntry = const <String, List<String>>{};
  ThemeMode _themeMode = ThemeMode.system;
  double _editorFontSize = 16;

  DateTime _selectedDate = DateTime.now();
  DateTime _calendarMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
  );
  Set<DateTime> _markedDates = <DateTime>{};

  Timer? _searchDebounce;
  Timer? _saveDebounce;

  String? _pendingId;
  String _pendingTitle = '';
  String _pendingBody = '';
  String? _pendingToast;

  List<Entry> get entries => List<Entry>.unmodifiable(_entries);
  Entry? get selected => _selected;
  SaveStatus get status => _status;
  String? get lastError => _lastError;
  String get query => _query;
  bool get loading => _loading;
  int get trashCount => _trashCount;
  ThemeMode get themeMode => _themeMode;
  double get editorFontSize => _editorFontSize;

  /// 日历当前选中的那天。
  DateTime get selectedDate => _selectedDate;

  /// 日历当前显示的月份（1 号）。
  DateTime get calendarMonth => _calendarMonth;

  /// 有日记的日期（日历上的小圆点）。
  Set<DateTime> get markedDates => Set<DateTime>.unmodifiable(_markedDates);

  /// 附件根目录（设置页展示/打开用）。
  String get attachmentsPath => store.directory.path;

  /// 全库日记（星图用；不受搜索过滤影响）。
  List<Entry> get allEntries => entryRepo.query();

  /// 全库附件索引关系（星图用）。
  List<Attachment> get allAttachments => attachmentRepo.all();

  /// 某篇日记的标签。
  List<String> tagsOf(String entryId) =>
      _tagsByEntry[entryId] ?? const <String>[];

  /// 全库标签名（设置页/建议用）。
  List<String> get allTagNames => tagRepo.allNames();

  /// 覆盖式设置标签；保存后刷新列表（标签也参与搜索）。
  Future<void> setTags(Entry entry, List<String> names) async {
    tagRepo.setTags(entry.id, names);
    await refresh();
    notifyListeners();
  }

  /// 给用户一条一次性提示（拖拽导入这类没有页面上下文的操作用）。
  void notifyUser(String message) {
    _pendingToast = message;
    notifyListeners();
  }

  /// 取走待显示的提示（取过即清空）。
  String? takeToast() {
    final message = _pendingToast;
    _pendingToast = null;
    return message;
  }

  Future<void> bootstrap() async {
    deviceId = metaRepo.get('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = newDeviceId();
      metaRepo.set('device_id', deviceId);
    }
    _themeMode = switch (metaRepo.get('theme_mode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _editorFontSize = ((metaRepo.getInt('editor_font_size') ?? 16).toDouble())
        .clamp(12, 28);
    _loading = false;
    await refresh();
    // 日历默认停在「最新的一天」：今天与最新一篇里更晚的那个。
    _selectedDate = _latestDay();
    _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
    notifyListeners();
  }

  Future<void> refresh() async {
    _entries
      ..clear()
      ..addAll(entryRepo.query(keyword: _query));
    _trashCount = entryRepo.count(deleted: true);
    _attachmentCounts = attachmentRepo.countsByEntry();
    _tagsByEntry = tagRepo.allTagsByEntry();
    _markedDates = entryRepo.datesWithEntries();
    if (_selected != null) {
      final id = _selected!.id;
      Entry? next;
      for (final entry in _entries) {
        if (entry.id == id) {
          next = entry;
          break;
        }
      }
      next ??= entryRepo.findById(id);
      _selected = (next == null || next.deletedAt != null) ? null : next;
    }
    notifyListeners();
  }

  // ───────────────────────────── 搜索 ─────────────────────────────

  void setQuery(String value) {
    _query = value;
    notifyListeners();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () => refresh());
  }

  // ───────────────────────────── 选中 ─────────────────────────────

  Future<void> select(Entry? entry) async {
    if (_selected?.id == entry?.id) return;
    await flushNow();
    _cleanupBlankDraft();
    _selected = entry;
    _pendingId = null;
    _pendingTitle = entry?.title ?? '';
    _pendingBody = entry?.bodyMd ?? '';
    _status = SaveStatus.idle;
    // 列表里点开某篇时，日历跟着跳到那天，两个入口不会互相打架。
    if (entry != null) {
      _selectedDate = _dayOf(entry.entryDate);
      _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
    }
    notifyListeners();
  }

  void _cleanupBlankDraft() {
    if (!_dirtyDraft) return;
    final current = _selected;
    _dirtyDraft = false;
    if (current == null) return;
    final fresh = entryRepo.findById(current.id);
    if (fresh != null && fresh.isBlank) {
      entryRepo.purge(fresh.id);
      _entries.removeWhere((e) => e.id == fresh.id);
    }
  }

  // ───────────────────────────── 新建 / 编辑 ─────────────────────────────

  Future<Entry> createEntry({DateTime? date}) async {
    await flushNow();
    _cleanupBlankDraft();
    final entry = entryRepo.create(deviceId: deviceId, date: date);
    _entries.insert(0, entry);
    _selected = entry;
    _pendingId = null;
    _pendingTitle = entry.title;
    _pendingBody = entry.bodyMd;
    _dirtyDraft = true;
    _status = SaveStatus.saved;
    notifyListeners();
    return entry;
  }

  // ───────────────────────────── 日历 ─────────────────────────────

  /// 切到某个月（只改显示，不建日记）。
  void showMonth(DateTime month) {
    _calendarMonth = DateTime(month.year, month.month);
    notifyListeners();
  }

  /// 点日历里的某天：那天已有日记就打开最近改过的一篇，没有就新建。
  Future<Entry> selectDay(DateTime day) async {
    final target = _dayOf(day);
    final existing = entryRepo.findLatestOn(target);
    if (existing != null) {
      await select(existing);
      _selectedDate = target;
      _calendarMonth = DateTime(target.year, target.month);
      notifyListeners();
      return existing;
    }
    final entry = await createEntry(date: target);
    // createEntry 把新条目插到列表最前面；按日期重排，历史日期才不会跑到今天上面。
    await refresh();
    _selectedDate = target;
    _calendarMonth = DateTime(target.year, target.month);
    notifyListeners();
    return entry;
  }

  /// 日历初始选中日：今天与最新一篇里更晚的那天（都按 00:00 比较）。
  DateTime _latestDay() {
    final today = _dayOf(DateTime.now());
    DateTime? latest;
    for (final entry in _entries) {
      final day = _dayOf(entry.entryDate);
      if (latest == null || day.isAfter(latest)) latest = day;
    }
    if (latest == null) return today;
    return latest.isAfter(today) ? latest : today;
  }

  static DateTime _dayOf(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// 编辑器每次输入调用；800ms 防抖后落库。
  void draftChanged({String? title, String? body, bool immediate = false}) {
    final current = _selected;
    if (current == null) return;
    if (title != null) _pendingTitle = title;
    if (body != null) _pendingBody = body;
    _pendingId = current.id;
    _status = SaveStatus.dirty;
    _lastError = null;
    notifyListeners();
    _saveDebounce?.cancel();
    if (immediate) {
      unawaited(flushNow());
    } else {
      _saveDebounce = Timer(autosaveDebounce, () => unawaited(flushNow()));
    }
  }

  Future<void> flushNow() async {
    _saveDebounce?.cancel();
    final id = _pendingId;
    if (id == null) return;
    final title = _pendingTitle;
    final body = _pendingBody;
    _status = SaveStatus.saving;
    notifyListeners();
    try {
      final saved = entryRepo.saveContent(id, title: title, body: body);
      // 只有写成功才清 pending：失败时必须保留，下一次 flush（输入/切走/Ctrl+S/
      // 关窗）会自动重试，否则一次写库失败就等于静默丢稿。
      _pendingId = null;
      final index = _entries.indexWhere((e) => e.id == id);
      if (index >= 0) _entries[index] = saved;
      if (_selected?.id == id) _selected = saved;
      _status = SaveStatus.saved;
      _lastError = null;
    } catch (error) {
      _status = SaveStatus.error;
      _lastError = error.toString();
    }
    notifyListeners();
  }

  /// 是否存在尚未成功写库的内容（保存失败时 UI 可据此提示「点此重试」）。
  bool get hasUnsavedChanges => _pendingId != null;

  Future<void> togglePin(Entry entry) async {
    await flushNow();
    entryRepo.setPinned(entry.id, !entry.pinned);
    await refresh();
  }

  // ───────────────────────────── 删除 / 回收站 ─────────────────────────────

  Future<void> deleteEntry(Entry entry) async {
    await flushNow();
    entryRepo.softDelete(entry.id);
    if (_selected?.id == entry.id) _selected = null;
    await refresh();
  }

  Future<void> restoreEntry(Entry entry) async {
    entryRepo.restore(entry.id);
    await refresh();
  }

  Future<void> purgeEntry(Entry entry) async {
    attachmentRepo.deleteByEntry(entry.id);
    entryRepo.purge(entry.id);
    if (_selected?.id == entry.id) _selected = null;
    await collectGarbage();
    await refresh();
  }

  Future<int> collectGarbage() async {
    final referenced = attachmentRepo.referencedHashes();
    return store.collectGarbage(referenced);
  }

  List<Entry> deletedEntries() => entryRepo.query(deleted: true);

  int attachmentCountOf(String entryId) => _attachmentCounts[entryId] ?? 0;

  List<Attachment> attachmentsOf(String entryId) =>
      attachmentRepo.listByEntry(entryId);

  String? localPathOf(Attachment attachment) =>
      store.pathFor(attachment.sha256, normalizeExtension(attachment.filename));

  // ───────────────────────────── 附件 ─────────────────────────────

  /// 弹出系统文件选择框，把文件存入附件库并写库，返回插入用的 Markdown 链接。
  Future<AttachedFile?> pickAttachment(Entry entry) async {
    final file = await _filePicker();
    if (file == null) return null;
    return attachBytes(entry, file.bytes, file.name);
  }

  Future<AttachedFile> attachBytes(
    Entry entry,
    Uint8List bytes,
    String filename,
  ) async {
    final blob = await store.storeBytes(bytes, filename);
    final attachment = attachmentRepo.insert(
      entryId: entry.id,
      sha256: blob.sha256,
      filename: filename,
      mime: mimeForFilename(filename),
      sizeBytes: blob.sizeBytes,
    );
    _attachmentCounts = attachmentRepo.countsByEntry();
    notifyListeners();
    return AttachedFile(
      attachment: attachment,
      blob: blob,
      isImage: isImageFileName(filename),
    );
  }

  Future<AttachedFile> attachPath(Entry entry, String path) async {
    final bytes = await File(path).readAsBytes();
    return attachBytes(entry, bytes, p.basename(path));
  }

  /// 把剪贴板里的图片（Windows 截图）落成附件；剪贴板没有图片时返回 null。
  Future<AttachedFile?> pasteClipboardImage(Entry entry) async {
    final bytes = await _clipboardImageReader();
    if (bytes == null || bytes.isEmpty) return null;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final name =
        '截图-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.png';
    return attachBytes(entry, bytes, name);
  }

  /// 从资源管理器拖进窗口的文件（Windows）：挂到当前正在写的日记上；  /// 没有打开的日记就先新建一篇。返回成功添加的个数。
  ///
  /// 与工具栏「插入附件」一致：除了落盘 + 写 attachments 表，还要把
  /// `assets/<sha>.<ext>` 引用插进正文，导出的 .md 才带着附件。
  Future<int> attachDroppedFiles(List<String> paths) async {
    final files = <String>[];
    for (final path in paths) {
      if (File(path).existsSync()) files.add(path);
    }
    if (files.isEmpty) return 0;

    final entry = _selected ?? await createEntry();
    var body = _selected?.id == entry.id ? _pendingBody : entry.bodyMd;
    var attached = 0;
    for (final path in files) {
      try {
        final result = await attachPath(entry, path);
        final current = body.trimRight();
        body = current.isEmpty
            ? result.markdownLink
            : '$current\n\n${result.markdownLink}';
        attached++;
      } on Object {
        // 单个文件失败（超限 / 被占用）不影响其余文件
      }
    }
    if (attached == 0) return 0;
    draftChanged(body: body, immediate: true);
    await flushNow();
    return attached;
  }

  /// 交给系统默认程序打开（附件预览、数据目录）。
  Future<void> openInSystem(String path) async {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>[
        '/c',
        'start',
        '',
        path,
      ], runInShell: false);
    } else if (Platform.isMacOS) {
      await Process.start('open', <String>[path]);
    } else {
      await Process.start('xdg-open', <String>[path]);
    }
  }

  // ───────────────────────────── 导入 / 导出 ─────────────────────────────

  Future<String?> pickDirectory({String title = '选择目录'}) async {
    return _directoryPicker(title);
  }

  // ───────────────────────────── 数据目录 ─────────────────────────────

  /// 当前数据目录的来源描述（设置页展示用）。
  String get dataRootSourceLabel => switch (AppPaths.resolution?.source) {
    DataRootSource.envOverride => '由环境变量 MDIARY_HOME 指定',
    DataRootSource.userChosen => '自定义目录',
    DataRootSource.portableDefault => '便携模式（mdiary.exe 同目录）',
    DataRootSource.appDataFallback => '系统用户目录（exe 目录不可写）',
    DataRootSource.tempFallback => '系统临时目录（重启后可能被清理）',
    null => '',
  };

  /// 把数据迁到 [target] 并切换过去。
  ///
  /// 顺序：落盘待保存内容 -> 校验目标 -> 关库 -> 复制并校验 -> 记住新位置 -> 重开 -> 删旧目录。
  /// 任何一步失败都会回滚到旧目录（旧数据原地不动），并把异常抛给调用方。
  Future<MigrationResult> changeDataRoot(String target) async {
    final oldRoot = dataRootPath;
    final normalized = p.canonicalize(target);
    if (p.equals(normalized, p.canonicalize(oldRoot))) {
      throw const DataRootMigrationException('这已经是当前数据目录');
    }

    await flushNow();
    _saveDebounce?.cancel();
    _searchDebounce?.cancel();

    final migration = DataRootMigration(source: oldRoot, target: normalized);
    await migration.validate();

    // 复制前必须关库：WAL 合并回主库，目标目录只需要一个 db/mdiary.sqlite。
    db.checkpoint();
    db.dispose();

    AppDatabase? reopened;
    try {
      final result = await migration.run();
      reopened = AppDatabase.open(
        DataRootMigration.databaseFileIn(normalized),
      );
      await AppPaths.switchTo(normalized);
      _rebind(normalized, reopened);
      reopened = null; // 所有权已交给 state
      await bootstrap();
      await DataRootMigration.removeOldRoot(
        oldRoot,
        exePath: Platform.resolvedExecutable,
      );
      return result;
    } catch (error) {
      reopened?.dispose();
      // 回滚：数据还在旧目录，重新打开旧库；位置指针也尽量改回去。
      try {
        await AppPaths.switchTo(oldRoot);
      } on Object {
        // 指针写不回去也不能让应用停在这里，内存里先回到旧目录。
      }
      _rebind(
        oldRoot,
        AppDatabase.open(DataRootMigration.databaseFileIn(oldRoot)),
      );
      await bootstrap();
      rethrow;
    }
  }

  /// 用一个数据库文件覆盖当前库（先校验、先备份，失败自动回滚）。
  ///
  /// 只替换 `db/mdiary.sqlite`；如果被导入库的旁边还有 `attachments/`（老版本把附件
  /// 放在磁盘上），会先把它复制进当前缓存目录，再回填进数据库。
  Future<DatabaseImportResult> importDatabase(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw const DataRootMigrationException('找不到数据库文件');
    }
    final live = File(DataRootMigration.databaseFileIn(dataRootPath));
    if (p.equals(p.canonicalize(source.path), p.canonicalize(live.path))) {
      throw const DataRootMigrationException('这就是当前正在使用的数据库');
    }

    final info = AppDatabase.inspect(source.path);
    if (!info.ok) {
      throw DataRootMigrationException('这不是可用的 SQLite 数据库：${info.integrity}');
    }
    if (info.version > AppDatabase.schemaVersion) {
      throw DataRootMigrationException(
        '这个库来自更新的版本（schema v${info.version}），'
        '当前程序最高支持 v${AppDatabase.schemaVersion}',
      );
    }

    await flushNow();
    _saveDebounce?.cancel();
    _searchDebounce?.cancel();
    db.checkpoint();
    db.dispose();

    Directory(live.parent.path).createSync(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .split('.')
        .first;
    final backup = File('${live.path}.bak-$stamp');
    if (live.existsSync()) live.copySync(backup.path);

    void removeSidecars() {
      for (final suffix in <String>['-wal', '-shm']) {
        final file = File('${live.path}$suffix');
        if (file.existsSync()) file.deleteSync();
      }
    }

    AppDatabase? opened;
    try {
      removeSidecars();
      source.copySync(live.path);
      opened = AppDatabase.open(live.path);
      _rebind(dataRootPath, opened);
      opened = null;
      await _importSiblingAttachments(source);
      await store.backfillFromFiles();
      await bootstrap();
      return DatabaseImportResult(
        source: source.path,
        backup: backup.path,
        entries: entryRepo.count(),
      );
    } catch (error) {
      opened?.dispose();
      // 回滚：把备份覆盖回去，重新打开旧库
      try {
        removeSidecars();
        if (backup.existsSync()) backup.copySync(live.path);
      } on Object {
        // 备份都写不回去时也没别的办法了，下面会用现有文件尽量恢复
      }
      _rebind(dataRootPath, AppDatabase.open(live.path));
      await bootstrap();
      throw DataRootMigrationException('导入失败，已恢复原来的数据库：$error');
    }
  }

  /// 老版本把附件放在库旁边的 `attachments/`：复制进当前缓存目录，稍后回填进库。
  Future<void> _importSiblingAttachments(File sourceDb) async {
    final candidates = <Directory>[
      Directory(p.join(sourceDb.parent.path, 'attachments')),
      Directory(p.join(sourceDb.parent.parent.path, 'attachments')),
    ];
    final target = store.directory;
    await target.create(recursive: true);
    for (final dir in candidates) {
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: dir.path);
        final out = File(p.join(target.path, relative));
        if (out.existsSync()) continue;
        await out.parent.create(recursive: true);
        await entity.copy(out.path);
      }
    }
  }

  /// 换一套连接/仓库/附件库，并把界面状态复位到「刚打开新库」。
  void _rebind(String rootPath, AppDatabase database) {    db = database;
    entryRepo = EntryRepository(database);
    attachmentRepo = AttachmentRepository(database);
    metaRepo = MetaRepository(database);
    tagRepo = TagRepository(database);
    store = AttachmentStore(
      Directory(p.join(rootPath, 'attachments')),
      blobs: attachmentRepo,
    );
    markdownIo = MarkdownIo(
      entries: entryRepo,
      attachments: attachmentRepo,
      store: store,
    );
    dataRootPath = rootPath;
    dataRootNotice = AppPaths.fallbackReason;
    _entries.clear();
    _selected = null;
    _pendingId = null;
    _pendingTitle = '';
    _pendingBody = '';
    _dirtyDraft = false;
    _status = SaveStatus.idle;
    _lastError = null;
    _trashCount = 0;
    _attachmentCounts = const <String, int>{};
  }

  Future<String?> exportCurrent(Entry entry) async {
    final dir = await pickDirectory(title: '选择导出目录');
    if (dir == null) return null;
    await flushNow();
    final fresh = entryRepo.findById(entry.id) ?? entry;
    return markdownIo.exportEntry(fresh, dir);
  }

  Future<ExportResult?> exportLibrary() async {
    final dir = await pickDirectory(title: '选择整库导出目录');
    if (dir == null) return null;
    await flushNow();
    return markdownIo.exportAll(dir);
  }

  Future<ImportResult?> importLibrary() async {
    final dir = await pickDirectory(title: '选择包含 .md 的目录');
    if (dir == null) return null;
    final result = await markdownIo.importDirectory(dir, deviceId: deviceId);
    await refresh();
    return result;
  }

  // ───────────────────────────── 设置 ─────────────────────────────

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    metaRepo.set('theme_mode', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
    notifyListeners();
  }

  void setEditorFontSize(double size) {
    _editorFontSize = size.clamp(12, 28);
    metaRepo.set('editor_font_size', _editorFontSize.round().toString());
    notifyListeners();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _saveDebounce?.cancel();
    super.dispose();
  }
}
