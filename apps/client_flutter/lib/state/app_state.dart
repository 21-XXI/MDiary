import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/ids.dart';
import '../data/attachment_repository.dart';
import '../data/attachment_store.dart';
import '../data/database.dart';
import '../data/entry_repository.dart';
import '../data/markdown_io.dart';
import '../data/meta_repository.dart';
import '../data/models.dart';

enum SaveStatus { idle, dirty, saving, saved, error }

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

  String get markdownLink => isImage
      ? '![](assets/${blob.sha256}${blob.ext})'
      : '[${attachment.filename}](assets/${blob.sha256}${blob.ext})';
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
  }) : _filePicker = filePicker ?? _defaultFilePicker,
       _directoryPicker = directoryPicker ?? _defaultDirectoryPicker;

  final AppDatabase db;
  final EntryRepository entryRepo;
  final AttachmentRepository attachmentRepo;
  final MetaRepository metaRepo;
  final AttachmentStore store;
  final MarkdownIo markdownIo;

  final SingleFilePicker _filePicker;
  final DirectoryPicker _directoryPicker;

  /// 数据根目录（设置页展示/打开用）。由 main 注入，UI 不直接依赖全局 AppPaths。
  final String dataRootPath;

  /// 默认数据目录不可写、退回备用目录时的说明；正常启动为 null。
  final String? dataRootNotice;

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
  ThemeMode _themeMode = ThemeMode.system;
  double _editorFontSize = 16;

  Timer? _searchDebounce;
  Timer? _saveDebounce;

  String? _pendingId;
  String _pendingTitle = '';
  String _pendingBody = '';

  List<Entry> get entries => List<Entry>.unmodifiable(_entries);
  Entry? get selected => _selected;
  SaveStatus get status => _status;
  String? get lastError => _lastError;
  String get query => _query;
  bool get loading => _loading;
  int get trashCount => _trashCount;
  ThemeMode get themeMode => _themeMode;
  double get editorFontSize => _editorFontSize;

  /// 附件根目录（设置页展示/打开用）。
  String get attachmentsPath => store.directory.path;

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
  }

  Future<void> refresh() async {
    _entries
      ..clear()
      ..addAll(entryRepo.query(keyword: _query));
    _trashCount = entryRepo.count(deleted: true);
    _attachmentCounts = attachmentRepo.countsByEntry();
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
