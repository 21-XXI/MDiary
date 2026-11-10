import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/clipboard_image.dart';
import '../core/ids.dart';
import '../core/system_open.dart';
import '../core/emoji.dart';
import '../core/secret_store.dart';
import '../rag/answer.dart';
import '../rag/agent_config.dart';
import '../rag/chat.dart';
import '../rag/diary_segmenter.dart';
import '../rag/cloud_client.dart';
import '../rag/embedder.dart';
import '../rag/memory_chat.dart';
import '../rag/model_registry.dart';
import '../rag/rag_settings.dart';
import '../rag/rag_service.dart';
import '../rag/report_job.dart';
import '../rag/semantic_indexer.dart';
import '../rag/soul_job.dart';
import '../rag/skill_job.dart';
import '../rag/summarizer.dart';
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

/// 一次「合并库」的统计。
class LibraryMergeResult {
  const LibraryMergeResult({
    required this.added,
    required this.updated,
    required this.attachmentsAdded,
    required this.blobsAdded,
  });

  /// 新加入的日记数。
  final int added;

  /// 因源库更新而覆盖的日记数。
  final int updated;

  /// 新增的附件索引条数（同 sha 共用字节）。
  final int attachmentsAdded;

  /// 新写入的附件字节份数（内容去重后）。
  final int blobsAdded;
}

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
    this.ragEmbedder,
    this.ragSummarizerOverride,
    this.ragAnswererOverride,
    this.skillDistillerOverride,
    RagSettingsStore? ragSettingsStore,
    ModelRegistryStore? modelRegistryStore,
    AgentConfigStore? agentConfigStore,
    this.memoryCompleterOverride,
    this.segmentCompleterOverride,
  }) : _filePicker = filePicker ?? _defaultFilePicker,
       _agentConfigStore = agentConfigStore ?? AgentConfigStore(),
       _modelRegistryStore = modelRegistryStore ?? ModelRegistryStore(),
       _ragSettingsStore = ragSettingsStore ?? RagSettingsStore(),
       _directoryPicker = directoryPicker ?? _defaultDirectoryPicker,
       _clipboardImageReader = clipboardImageReader ?? ClipboardImage.read,
       tagRepo = tagRepository ?? TagRepository(db) {
    _ragSettings = _ragSettingsStore.load();
    _modelRegistry = _modelRegistryStore.load();
    _agentConfig = _agentConfigStore.load();
    if (_modelRegistry.isEmpty) {
      _modelRegistry = ModelRegistry.migration(_ragSettings);
      _modelRegistryStore.save(_modelRegistry);
    }
  }

  AppDatabase db;
  EntryRepository entryRepo;
  AttachmentRepository attachmentRepo;
  MetaRepository metaRepo;
  TagRepository tagRepo;
  AttachmentStore store;
  MarkdownIo markdownIo;

  /// 测试可注入的 RAG 依赖（默认走本地 Ollama）。
  final Embedder? ragEmbedder;
  final Summarizer? ragSummarizerOverride;
  final Answerer? ragAnswererOverride;
  final SkillDistiller? skillDistillerOverride;

  /// 测试用：替代记忆对话的模型调用。
  final Future<String> Function(String prompt)? memoryCompleterOverride;

  /// 测试用：替代分词模型的调用。
  final Future<String> Function(String prompt)? segmentCompleterOverride;
  final RagSettingsStore _ragSettingsStore;
  final ModelRegistryStore _modelRegistryStore;
  final AgentConfigStore _agentConfigStore;
  AgentConfig _agentConfig = const AgentConfig();
  late RagSettings _ragSettings;
  ModelRegistry _modelRegistry = const ModelRegistry();

  /// 当前模型设置（全局，写在 `<数据目录>/settings.json`）。
  RagSettings get ragSettings => _ragSettings;

  /// 统一模型配置（`<数据目录>/models.json`）。
  ModelRegistry get modelRegistry => _modelRegistry;

  String? get modelsPath => _modelRegistryStore.path;

  /// 读取 md 附件正文。
  String? attachmentText(Attachment attachment) {
    final bytes = attachmentRepo.readBlob(attachment.sha256);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 新建或更新一个「附加 md 笔记」，并同步主文件里的链接。
  Future<Attachment> saveMarkdownNote(
    Entry entry, {
    required String filename,
    required String text,
    Attachment? existing,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final blob = await store.storeBytes(bytes, filename);
    const mime = 'text/x-mdiary-note';
    final current = entryRepo.findById(entry.id) ?? entry;
    Attachment attachment;
    String body;
    if (existing != null) {
      attachmentRepo.updateContent(
        id: existing.id,
        sha256: blob.sha256,
        sizeBytes: blob.sizeBytes,
        mime: mime,
        filename: filename,
      );
      attachment = Attachment(
        id: existing.id,
        entryId: existing.entryId,
        sha256: blob.sha256,
        filename: filename,
        mime: mime,
        sizeBytes: blob.sizeBytes,
        createdAt: existing.createdAt,
      );
      body = current.bodyMd
          .replaceAll('assets/${existing.sha256}', 'assets/${blob.sha256}')
          .replaceAll('[${existing.filename}]', '[$filename]');
    } else {
      attachment = attachmentRepo.insert(
        entryId: entry.id,
        sha256: blob.sha256,
        filename: filename,
        mime: mime,
        sizeBytes: blob.sizeBytes,
      );
      body = '${entry.bodyMd.trimRight()}\n- [$filename](assets/${blob.sha256}.md)\n';
    }
    entryRepo.saveContent(entry.id, body: body);
    // 编辑会生成新 blob，旧 blob 不再被引用：顺手清理。
    attachmentRepo.deleteUnreferencedBlobs();
    await refresh();
    _scheduleRagReindex();
    return attachment;
  }

  AgentConfig get agentConfig => _agentConfig;

  String get agentRunsPath => AgentRunLog.pathFor(libraryPath);

  List<AgentRun> loadAgentRuns() => AgentRunLog(agentRunsPath).load();

  void setAgentConfig(AgentConfig next) {
    _agentConfig = next;
    _agentConfigStore.save(next);
    notifyListeners();
  }

  void clearAgentRuns() {
    AgentRunLog(agentRunsPath).clear();
    notifyListeners();
  }

  Timer? _ragReindexTimer;

  /// 保存子笔记后防抖重建索引，避免连续编辑反复全量扫描。
  void _scheduleRagReindex() {
    _ragReindexTimer?.cancel();
    _ragReindexTimer = Timer(const Duration(seconds: 5), () async {
      try {
        await rag.reindex();
      } on Object {
        // 模型不可用或索引库未就绪：下次每日任务会补
      }
    });
  }

  void _logAgent(String kind, int steps, bool ok, String message) {
    if (!_agentConfig.logEnabled) return;
    AgentRunLog(agentRunsPath).append(
      AgentRun(
        kind: kind,
        startedAt: DateTime.now(),
        steps: steps,
        ok: ok,
        message: message,
      ),
    );
  }

  ModelProfile? profileFor(ModelRole role) => _modelRegistry.profileFor(role);

  void saveModelRegistry(ModelRegistry next) {
    _modelRegistry = next;
    _modelRegistryStore.save(next);
    // 向量模型可能变了：关闭旧索引连接，下次检索重建。
    _rag?.close();
    _rag = null;
    notifyListeners();
  }

  void upsertModelProfile(ModelProfile profile) =>
      saveModelRegistry(_modelRegistry.withProfile(profile));

  void removeModelProfile(String id) =>
      saveModelRegistry(_modelRegistry.withoutProfile(id));

  /// 测试某个模型配置是否可用；成功返回 null。
  Future<String?> testModelProfile(ModelProfile profile) async {
    if (!profile.isCloud) {
      final models = await listOllamaModels(baseUrl: profile.baseUrl);
      final found = models.any(
        (name) => name == profile.model || name.startsWith('${profile.model}:'),
      );
      return found ? null : '没有找到模型 ${profile.model}';
    }
    final key = SecretStore.unprotect(profile.apiKeyCipher);
    if (key == null || key.trim().isEmpty) return '还没有配置 API Key';
    final available = await CloudAnswerer(
      CloudConfig(
        baseUrl: profile.baseUrl,
        model: profile.model,
        apiKey: key.trim(),
        temperature: profile.temperature,
      ),
    ).isAvailable();
    return available ? null : '连不上 ${profile.baseUrl} 或 Key 无效';
  }

  void setRoleProfile(ModelRole role, String? profileId) =>
      saveModelRegistry(_modelRegistry.withRole(role, profileId));

  /// 用某个角色的模型做一次非流式补全（分词 / 记忆对话等）。
  Future<String> completeForRole(ModelRole role, String prompt) async {
    final profile = _modelRegistry.profileFor(role);
    if (profile != null) {
      if (profile.isCloud) {
        final key = SecretStore.unprotect(profile.apiKeyCipher);
        if (key != null && key.isNotEmpty) {
          return CloudCompleter(
            CloudConfig(
              baseUrl: profile.baseUrl,
              model: profile.model,
              apiKey: key,
            ),
          ).complete(prompt);
        }
      } else {
        return OllamaAnswerer(
          model: profile.model,
          baseUrl: profile.baseUrl,
        ).complete(prompt);
      }
    }
    return OllamaAnswerer(
      model: _ragSettings.generateModel,
      baseUrl: _ragSettings.baseUrl,
    ).complete(prompt);
  }

  // ───────────────────────────── 记忆对话（v2.7） ─────────────────────────────

  String get memoryChatPath => MemoryChatStore.pathFor(libraryPath);

  List<MemoryMessage> loadMemoryChat() =>
      MemoryChatStore(memoryChatPath).load();

  static const String memoryModelPreset = '__model__';
  static const String memoryLatestSkill = '__latest__';

  /// 记忆对话当前选择的 skill：`__model__` / `__latest__` / skill 目录名。
  String get memorySkillSelection =>
      metaRepo.get('memory_skill') ?? memoryLatestSkill;

  void setMemorySkill(String value) {
    metaRepo.set('memory_skill', value);
    notifyListeners();
  }

  String? get memorySkillName {
    final selection = memorySkillSelection;
    final skills = listSkills();
    if (selection == memoryModelPreset) return '模型默认预设';
    if (selection == memoryLatestSkill) {
      return skills.isEmpty ? '模型默认预设' : skills.first.name;
    }
    for (final skill in skills) {
      if (skill.name == selection) return skill.name;
    }
    return '未找到，已回退模型默认预设';
  }

  String _memorySkillMarkdown() {
    final selection = memorySkillSelection;
    final skills = listSkills();
    if (selection == memoryModelPreset || skills.isEmpty) return '';
    if (selection == memoryLatestSkill) return skills.first.markdown;
    for (final skill in skills) {
      if (skill.name == selection) return skill.markdown;
    }
    return '';
  }
  /// 只用蒸馏 skill 的记忆对话（不检索日记）；按库持久化。
  Future<MemoryMessage> askMemory(String question) async {
    if (!_agentConfig.allowReadSkill) {
      throw StateError('Agent 权限关闭：读取 skill');
    }
    final skillMarkdown = _memorySkillMarkdown();
    final history = loadMemoryChat();
    final prompt = buildMemoryPrompt(
      skill: skillMarkdown,
      history: history,
      question: question,
    );
    final store = MemoryChatStore(memoryChatPath);
    store.append(
      MemoryMessage(
        fromUser: true,
        text: question,
        createdAt: DateTime.now(),
      ),
    );
    final answer = memoryCompleterOverride != null
        ? await memoryCompleterOverride!(prompt)
        : await completeForRole(ModelRole.memory, prompt);
    final reply = MemoryMessage(
      fromUser: false,
      text: answer.trim(),
      createdAt: DateTime.now(),
    );
    store.append(reply);
    _logAgent('memory', 1, true, skillMarkdown.isEmpty ? '普通对话（模型默认预设）' : question);
    notifyListeners();
    return reply;
  }

  void clearMemoryChat() {
    MemoryChatStore(memoryChatPath).clear();
    notifyListeners();
  }

  /// 读取文件夹并让分词模型给出切分计划（不落库）；解析失败会重试，最多 maxSteps 次。
  Future<SegmentPlan> planSegmentation(String directory) async {
    if (!_agentConfig.allowReadFolder) {
      throw const SegmenterException('Agent 权限关闭：读取文件夹');
    }
    final segmenter = DiarySegmenter(
      complete: segmentCompleterOverride ??
          ((prompt) => completeForRole(ModelRole.segment, prompt)),
    );
    Object? lastError;
    for (var step = 1; step <= _agentConfig.maxSteps; step++) {
      try {
        final plan = await segmenter.planDirectory(directory);
        _logAgent('segment', step, true, '切出 ${plan.days.length} 天');
        return plan;
      } on Object catch (error) {
        lastError = error;
      }
    }
    _logAgent('segment', _agentConfig.maxSteps, false, '$lastError');
    throw SegmenterException('$lastError');
  }

  /// 新建库 → 把切分结果写成日期文件夹 → 导入 → 切换过去。
  Future<ImportResult> importSegmentPlan(
    SegmentPlan plan, {
    required String sourceDirectory,
    required String libraryName,
  }) async {
    if (!_agentConfig.allowCreateLibrary) {
      throw const SegmenterException('Agent 权限关闭：新建库');
    }
    if (!_agentConfig.allowWriteDiary) {
      throw const SegmenterException('Agent 权限关闭：写入日记');
    }
    final root = AppPaths.isInitialized ? AppPaths.root.path : dataRootPath;
    final parent = p.join(root, 'libraries');
    Directory(parent).createSync(recursive: true);
    final dir = _uniqueDirectory(parent, _safeName(libraryName));
    Directory(dir).createSync(recursive: true);
    await switchLibrary(dir);

    final stagingRoot = Directory(p.join(root, 'tmp', 'segment-${DateTime.now().millisecondsSinceEpoch}'))
      ..createSync(recursive: true);
    final staging = Directory(p.join(stagingRoot.path, 'content'))..createSync();
    final notesDir = Directory(p.join(stagingRoot.path, 'notes'))..createSync();
    try {
      final source = Directory(sourceDirectory);
      for (final day in plan.days) {
        final date = day.date;
        final stamp =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        final folder = Directory(p.join(staging.path, stamp))..createSync(recursive: true);
        final buffer = StringBuffer()
          ..writeln('---')
          ..writeln('title: ${day.title}')
          ..writeln('date: $stamp')
          ..writeln('tags: [${day.tags.join(', ')}]')
          ..writeln('---')
          ..writeln()
          ..writeln(day.body.trim());
        for (final note in day.notes) {
          buffer
            ..writeln()
            ..writeln('- [${note.filename}](notes/${note.filename})');
          File(p.join(notesDir.path, '$stamp-${note.filename}')).writeAsStringSync(
            note.body,
            flush: true,
          );
        }
        for (final name in day.attachments) {
          final file = _findFile(source, name);
          if (file == null) continue;
          file.copySync(p.join(folder.path, name));
          buffer
            ..writeln()
            ..writeln('![$name]($name)');
        }
        File(p.join(folder.path, '当期.md')).writeAsStringSync(
          buffer.toString(),
          flush: true,
        );
      }
      final result = await markdownIo.importDirectory(
        staging.path,
        deviceId: deviceId,
      );
      // 附加笔记作为附件挂到当天主文件，并把 notes/ 链接改成 assets/<sha>.md。
      for (final day in plan.days) {
        if (day.notes.isEmpty) continue;
        Entry? entry;
        for (final candidate in entryRepo.query()) {
          if (candidate.isDeleted) continue;
          if (candidate.entryDate.year == day.date.year &&
              candidate.entryDate.month == day.date.month &&
              candidate.entryDate.day == day.date.day) {
            entry = candidate;
            break;
          }
        }
        if (entry == null) continue;
        var body = entry.bodyMd;
        for (final note in day.notes) {
          final blob = await store.storeBytes(
            Uint8List.fromList(utf8.encode(note.body)),
            note.filename,
          );
          attachmentRepo.insert(
            entryId: entry.id,
            sha256: blob.sha256,
            filename: note.filename,
            mime: 'text/x-mdiary-note',
            sizeBytes: blob.sizeBytes,
          );
          body = body.replaceAll(
            'notes/${note.filename}',
            'assets/${blob.sha256}.md',
          );
        }
        entryRepo.saveContent(entry.id, body: body);
      }
      await refresh();
      return result;
    } finally {
      if (stagingRoot.existsSync()) stagingRoot.deleteSync(recursive: true);
    }
  }

  static String _safeName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').trim();
    return cleaned.isEmpty ? '导入库' : cleaned;
  }

  static File? _findFile(Directory root, String name) {
    if (!root.existsSync()) return null;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path) == name) return entity;
    }
    return null;
  }

  void updateRagSettings(RagSettings next) {
    final embedChanged =
        next.embedModel != _ragSettings.embedModel ||
        next.baseUrl != _ragSettings.baseUrl;
    _ragSettings = next;
    _ragSettingsStore.save(next);
    if (embedChanged) {
      _rag?.close();
      _rag = null;
    }
    notifyListeners();
  }

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
  String? _tagFilter;
  List<String> _recentQueries = const <String>[];
  bool _loading = true;
  bool _dirtyDraft = false;
  int _trashCount = 0;
  Map<String, int> _attachmentCounts = const <String, int>{};
  Map<String, List<String>> _tagsByEntry = const <String, List<String>>{};
  ThemeMode _themeMode = ThemeMode.system;
  double _editorFontSize = 16;
  String _uiFont = '';
  String _editorFont = 'Cascadia Mono';
  Map<String, String> _emojiCustom = const <String, String>{};

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

  /// 当前按标签筛选（null 表示全部）。
  String? get tagFilter => _tagFilter;

  /// 库里出现过的所有标签名（左栏筛选条用）。
  List<String> get allTags => tagRepo.allNames();

  /// 最近搜索过的关键词（最多 8 个）。
  List<String> get recentQueries => _recentQueries;

  void setTagFilter(String? tag) {
    if (_tagFilter == tag) return;
    _tagFilter = tag;
    notifyListeners();
    refresh();
  }

  /// 记一条搜索历史（去重、最多 8 条，存在 app_meta 里）。
  void rememberQuery(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    final next = <String>[
      query,
      ..._recentQueries.where((item) => item != query),
    ].take(8).toList(growable: false);
    if (_listEquals(next, _recentQueries)) return;
    _recentQueries = next;
    metaRepo.set('recent_queries', jsonEncode(next));
    notifyListeners();
  }

  void clearQueryHistory() {
    _recentQueries = const <String>[];
    metaRepo.set('recent_queries', '[]');
    notifyListeners();
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<String> _readRecentQueries() {
    final raw = metaRepo.get('recent_queries');
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded.whereType<String>().take(8).toList(growable: false);
    } on Object {
      return const <String>[];
    }
  }
  bool get loading => _loading;
  int get trashCount => _trashCount;
  ThemeMode get themeMode => _themeMode;
  double get editorFontSize => _editorFontSize;

  /// 界面字体（空 = 系统默认回落链）。
  String get uiFont => _uiFont;

  /// 编辑器等宽字体。
  String get editorFont => _editorFont;

  /// 用户自定义/覆盖的表情短代码。
  Map<String, String> get emojiCustom => _emojiCustom;

  /// 内置 + 自定义（自定义优先）。
  Map<String, String> get emojiMap => <String, String>{
    ...builtinEmoji,
    ..._emojiCustom,
  };

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
  /// 每个标签的使用次数（标签管理）。
  Map<String, int> get tagCounts => tagRepo.counts();

  /// 重命名标签；合并到已有名字时两边条目会合并。
  Future<void> renameTag(String from, String to) async {
    tagRepo.rename(from, to);
    if (_tagFilter == from) _tagFilter = to;
    await refresh();
  }

  /// 删除标签（只解除标记，不删日记）。
  Future<void> removeTag(String name) async {
    tagRepo.remove(name);
    if (_tagFilter == name) _tagFilter = null;
    await refresh();
  }

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
    _uiFont = metaRepo.get('ui_font') ?? '';
    _editorFont = metaRepo.get('editor_font') ?? 'Cascadia Mono';
    _emojiCustom = _readEmojiCustom();
    _recentQueries = _readRecentQueries();
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
      ..addAll(entryRepo.query(keyword: _query, tag: _tagFilter));
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

  List<Entry> deletedEntries({bool byDeletedAt = true}) =>
      entryRepo.query(deleted: true, byDeletedAt: byDeletedAt);

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
    return _attachBlob(entry, blob, filename);
  }

  /// 从磁盘路径入库：分块算 sha256，库里已有这份字节时不再读文件内容。
  Future<AttachedFile> attachPath(Entry entry, String path) async {
    final blob = await store.storeFile(path);
    return _attachBlob(entry, blob, p.basename(path));
  }

  Future<AttachedFile> _attachBlob(
    Entry entry,
    StoredBlob blob,
    String filename,
  ) async {
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

  /// 交给系统默认程序打开（附件预览、数据目录、URL）。
  ///
  /// Windows 走 runner 的 ShellExecuteW（不经过 cmd 解析），其它平台用 open/xdg-open。
  Future<void> openInSystem(String path) async {
    await SystemOpen.open(path);
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

  /// 当前库的数据库文件路径（备份/压缩用）。
  String get databaseFilePath => AppPaths.isInitialized
      ? AppPaths.databaseFile
      : DataRootMigration.databaseFileIn(dataRootPath);

  /// 当前库的备份目录（`<库目录>/backups`）。
  String get backupDirectory => p.join(p.dirname(databaseFilePath), 'backups');

  /// 手动备份：`VACUUM INTO` 生成一致性快照，保留最近 7 份。返回备份文件路径。
  Future<String> backupDatabase() async {
    final source = File(databaseFilePath);
    if (!source.existsSync()) {
      throw const DataRootMigrationException('当前数据库不是磁盘库，无法备份');
    }
    await flushNow();
    final dir = Directory(backupDirectory)..createSync(recursive: true);
    final target = p.join(dir.path, 'mdiary-${_fileTimestamp()}.sqlite');
    db.backupTo(target);
    _pruneBackups(dir);
    return target;
  }

  /// 超过 24 小时没有备份就自动备份一份；不需要时返回 null。
  Future<String?> autoBackupIfDue() async {
    final source = File(databaseFilePath);
    if (!source.existsSync()) return null;
    final backups = listBackups();
    if (backups.isNotEmpty &&
        DateTime.now().difference(backups.first.lastModifiedSync()) <
            const Duration(hours: 24)) {
      return null;
    }
    try {
      return await backupDatabase();
    } on Object {
      return null; // 备份失败不能挡住启动
    }
  }

  /// 备份文件，最新的在前。
  List<File> listBackups() {
    final dir = Directory(backupDirectory);
    if (!dir.existsSync()) return const <File>[];
    final files =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.sqlite'))
            .toList()
          ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  void _pruneBackups(Directory dir, {int keep = 7}) {
    final files =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.sqlite'))
            .toList()
          ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final file in files.skip(keep)) {
      try {
        file.deleteSync();
      } on Object {
        // 删不掉就留着，不影响使用
      }
    }
  }

  /// 压缩数据库，返回（压缩前, 压缩后）字节数。
  Future<(int, int)> compactDatabase() async {
    final file = File(databaseFilePath);
    if (!file.existsSync()) {
      throw const DataRootMigrationException('当前数据库不是磁盘库，无法压缩');
    }
    await flushNow();
    // 先合并 WAL，否则量到的主库文件大小是"假小"
    db.checkpoint();
    final before = file.lengthSync();
    db.compact();
    final after = file.lengthSync();
    notifyListeners();
    return (before, after);
  }

  /// 附件缓存占用的字节数。
  Future<int> attachmentCacheBytes() => store.cacheBytes();

  /// 清空附件缓存（字节在库里，下次预览/打开会自动重建），返回释放的字节数。
  Future<int> clearAttachmentCache() async {
    final freed = await store.clearCache();
    notifyListeners();
    return freed;
  }

  static String _fileTimestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '-${now.millisecond.toString().padLeft(3, '0')}';
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

  // ───────────────────────────── RAG（v2.0） ─────────────────────────────

  RagService? _rag;

  /// 本地 RAG：索引 / 检索 / 日报 / 灵魂档案共用（首次访问时打开）。
  RagService get rag => _rag ??= RagService.open(
    libraryRoot: libraryPath,
    entries: entryRepo,
    attachments: attachmentRepo,
    tags: tagRepo,
    store: store,
    embedder:
        ragEmbedder ??
        OllamaEmbedder(
          model: _ragSettings.embedModel,
          baseUrl: _ragSettings.baseUrl,
        ),
  );

  /// 当前云端的配置（优先「模型」里的云端配置）。
  ModelProfile? get cloudProfile {
    final generate = _modelRegistry.profileFor(ModelRole.generate);
    if (generate != null && generate.isCloud) return generate;
    for (final profile in _modelRegistry.profiles) {
      if (profile.isCloud) return profile;
    }
    return null;
  }

  /// 云端配置；未开启或没有 Key 时为 null（走本地）。
  CloudConfig? get cloudConfig {
    if (!_ragSettings.cloudEnabled) return null;
    final profile = cloudProfile;
    if (profile != null) {
      final key = SecretStore.unprotect(profile.apiKeyCipher);
      if (key != null && key.trim().isNotEmpty) {
        return CloudConfig(
          baseUrl: profile.baseUrl,
          model: profile.model,
          apiKey: key.trim(),
        );
      }
    }
    // 兼容旧 settings.json 里的 Key（迁移后会写进模型配置）。
    final legacy = SecretStore.unprotect(_ragSettings.cloudApiKeyCipher);
    if (legacy == null || legacy.trim().isEmpty) return null;
    return CloudConfig(
      baseUrl: _ragSettings.cloudBaseUrl,
      model: _ragSettings.cloudModel,
      apiKey: legacy.trim(),
    );
  }

  bool get cloudEnabled => cloudConfig != null;

  Summarizer get ragSummarizer {
    final override = ragSummarizerOverride;
    if (override != null) return override;
    final profile = _modelRegistry.profileFor(ModelRole.generate);
    if (profile != null) {
      if (profile.isCloud) {
        final key = SecretStore.unprotect(profile.apiKeyCipher);
        if (key != null && key.isNotEmpty) {
          return CloudSummarizer(
            CloudConfig(
              baseUrl: profile.baseUrl,
              model: profile.model,
              apiKey: key,
            ),
          );
        }
      } else {
        return OllamaSummarizer(
          model: profile.model,
          baseUrl: profile.baseUrl,
        );
      }
    }
    return cloudConfig != null
        ? CloudSummarizer(cloudConfig!)
        : OllamaSummarizer(
            model: _ragSettings.generateModel,
            baseUrl: _ragSettings.baseUrl,
          );
  }

  Answerer get ragAnswerer {
    final override = ragAnswererOverride;
    if (override != null) return override;
    final profile = _modelRegistry.profileFor(ModelRole.chat);
    if (profile != null) {
      if (profile.isCloud) {
        final key = SecretStore.unprotect(profile.apiKeyCipher);
        if (key != null && key.isNotEmpty) {
          return CloudAnswerer(
            CloudConfig(
              baseUrl: profile.baseUrl,
              model: profile.model,
              apiKey: key,
              temperature: profile.temperature,
            ),
          );
        }
      } else {
        return OllamaAnswerer(
          model: profile.model,
          baseUrl: profile.baseUrl,
          temperature: profile.temperature,
          numCtx: profile.numCtx,
        );
      }
    }
    return cloudConfig != null
        ? CloudAnswerer(cloudConfig!)
        : OllamaAnswerer(
            model: _ragSettings.askModel,
            baseUrl: _ragSettings.baseUrl,
          );
  }

  // ───────────────────────────── 蒸馏 skill（v2.2） ─────────────────────────────

  bool get skillEnabled => _ragSettings.skillEnabled;

  /// 能否蒸馏：需要云端，或测试里注入了 distiller。
  bool get canDistill => cloudConfig != null || skillDistillerOverride != null;

  void setSkillEnabled(bool enabled) {
    updateRagSettings(_ragSettings.copyWith(skillEnabled: enabled));
  }

  /// 生成一份新的 skill；旧目录不会覆盖。
  ///
  /// 需要：开关打开 + 云端模型可用（或在测试里注入 [skillDistillerOverride]）。
  Future<DistilledSkill> distillSkill() async {
    if (!skillEnabled) {
      throw SkillUnavailable('先在「蒸馏」页打开开关');
    }
    final distiller = skillDistillerOverride ?? _requireCloudDistiller();
    var soul = soulJob.read();
    if (soul == null || soul.trim().isEmpty) {
      await soulJob.generate(force: true);
      soul = soulJob.read();
    }
    return SkillJob(
      rag: rag.database,
      entries: entryRepo,
      tags: tagRepo,
      distiller: distiller,
    ).run(soulMarkdown: soul);
  }

  /// 生成预览，不落盘。
  Future<String> previewSkill() async {
    if (!skillEnabled) {
      throw SkillUnavailable('先在「蒸馏」页打开开关');
    }
    final distiller = skillDistillerOverride ?? _requireCloudDistiller();
    var soul = soulJob.read();
    if (soul == null || soul.trim().isEmpty) {
      await soulJob.generate(force: true);
      soul = soulJob.read();
    }
    return SkillJob(
      rag: rag.database,
      entries: entryRepo,
      tags: tagRepo,
      distiller: distiller,
    ).preview(soulMarkdown: soul);
  }

  /// 预览确认后保存为新 skill。
  Future<DistilledSkill> saveSkill(String markdown) async {
    final distiller = skillDistillerOverride ?? _requireCloudDistiller();
    return SkillJob(
      rag: rag.database,
      entries: entryRepo,
      tags: tagRepo,
      distiller: distiller,
    ).save(markdown);
  }

  SkillDistiller _requireCloudDistiller() {
    final config = cloudConfig;
    if (config == null) {
      throw SkillUnavailable('蒸馏使用云端大模型：请先在设置里开启云端并填 API Key');
    }
    return CloudSkillDistiller(config);
  }

  List<SkillEntry> listSkills() =>
      SkillJob.listIn(SkillJob.directoryFor(rag.database));

  /// 保存云端 API Key（DPAPI 加密后写 settings.json）。
  void setCloudApiKey(String plain) {
    final cipher = plain.trim().isEmpty
        ? ''
        : SecretStore.protect(plain.trim());
    final existing = cloudProfile;
    final next = (existing ??
            ModelProfile(
              id: 'cloud-generate',
              name: '云端 · 生成',
              provider: 'openai',
              baseUrl: _ragSettings.cloudBaseUrl,
              model: _ragSettings.cloudModel,
            ))
        .copyWith(apiKeyCipher: cipher);
    saveModelRegistry(_modelRegistry.withProfile(next));
  }

  /// 测试云端连通性；成功返回 null，失败返回原因。
  Future<String?> testCloud() async {
    final config = cloudConfig;
    if (config == null) return '还没有开启云端或没填 API Key';
    final answerer = CloudAnswerer(config);
    if (await answerer.isAvailable()) return null;
    return '连不上 ${config.baseUrl} 或 Key 无效';
  }

  /// 对话模式：模型先改写检索词 → 混合检索 → 带引用回答。
  Future<ChatReply> chatAsk(
    String question, {
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) => RagChat(
    search: (query, k) => ragSearch(query, k: k),
    answerer: ragAnswerer,
  ).ask(question: question, history: history);

  /// 用当前命中的来源生成回答（流式，可带最近的对话上下文）。
  Stream<String> streamAnswer(
    String question,
    List<RagHit> hits, {
    List<AnswerTurn> history = const <AnswerTurn>[],
  }) {
    final sources = <AnswerSource>[
      for (final hit in hits)
        AnswerSource(
          label: hit.label,
          date: hit.date,
          text: hit.text,
          kind: hit.kind,
        ),
    ];
    return ragAnswerer.streamAnswer(
      question: question,
      sources: sources,
      history: history,
    );
  }

  /// 本机 Ollama 已安装的模型（设置页下拉用）。
  Future<List<String>> installedModels() =>
      listOllamaModels(baseUrl: _ragSettings.baseUrl);

  DailyReportJob get reportJob => DailyReportJob(
    rag: rag.database,
    entries: entryRepo,
    attachments: attachmentRepo,
    summarizer: ragSummarizer,
  );

  SoulJob get soulJob => SoulJob(
    rag: rag.database,
    entries: entryRepo,
    tags: tagRepo,
    attachments: attachmentRepo,
    summarizer: ragSummarizer,
  );

  Future<List<RagHit>> ragSearch(String query, {int k = 8}) =>
      rag.search(query, k: k);

  Future<IndexReport> reindexRag({
    bool force = false,
    void Function(IndexProgress progress)? onProgress,
  }) => rag.reindex(force: force, onProgress: onProgress);

  RagStats get ragStats => rag.stats();

  List<DateTime> ragReportDates() => reportJob.reportDates();

  String? ragReportMarkdown(DateTime date) => reportJob.markdownOf(date);

  Future<DailyReportRun> backfillReports({bool force = false}) =>
      reportJob.backfill(force: force);

  Future<DailyReportResult> generateReport(DateTime date, {bool force = false}) =>
      reportJob.generate(date, force: force);

  String? soulMarkdown() => soulJob.read();

  Future<SoulReport> regenerateSoul({bool force = true}) =>
      soulJob.generate(force: force);

  Attachment? attachmentById(String? id) =>
      id == null ? null : attachmentRepo.findById(id);

  // ───────────────────────────── 库（可切换的数据库） ─────────────────────────────

  /// 当前库目录（里面放着 `mdiary.sqlite`）。
  String get libraryPath => AppPaths.isInitialized
      ? AppPaths.libraryDir
      : p.join(dataRootPath, 'db');

  /// 最近用过的库目录（设置页快速切换）。
  List<String> get recentLibraries =>
      AppPaths.isInitialized ? AppPaths.loadRecentLibraries() : const <String>[];

  /// 切换库：目录里已有 `mdiary.sqlite` 就用它，没有就新建一个空库。
  Future<void> switchLibrary(String dirPath) async {
    final oldDir = AppPaths.libraryDir;
    final normalized = p.canonicalize(dirPath);
    if (p.equals(normalized, p.canonicalize(oldDir))) {
      throw const DataRootMigrationException('这已经是当前库');
    }
    final target = File(AppPaths.libraryDatabaseFileIn(normalized));
    if (target.existsSync()) {
      final info = AppDatabase.inspect(target.path);
      if (!info.ok) {
        throw DataRootMigrationException('这个库不可用：${info.integrity}');
      }
      if (info.version > AppDatabase.schemaVersion) {
        throw DataRootMigrationException(
          '这个库来自更新的版本（schema v${info.version}）',
        );
      }
    }
    Directory(normalized).createSync(recursive: true);

    await flushNow();
    _saveDebounce?.cancel();
    _searchDebounce?.cancel();
    db.checkpoint();
    db.dispose();

    AppDatabase? opened;
    try {
      opened = AppDatabase.open(target.path);
      await AppPaths.adoptLibrary(normalized);
      _rebind(dataRootPath, opened);
      opened = null;
      await store.backfillFromFiles();
      await bootstrap();
    } catch (error) {
      opened?.dispose();
      try {
        await AppPaths.adoptLibrary(oldDir);
      } on Object {
        // 记不住也没关系，至少把数据连接切回去
      }
      _rebind(
        dataRootPath,
        AppDatabase.open(AppPaths.libraryDatabaseFileIn(oldDir)),
      );
      await bootstrap();
      throw DataRootMigrationException('切换库失败，已回到原来的库：$error');
    }
  }

  /// 把一个外部 `.sqlite` 作为新库导入：复制到 `<数据目录>/libraries/<名字>/` 并切换过去。
  /// 返回新库目录。
  Future<String> importDatabaseAsLibrary(
    String sqlitePath, {
    String? folderName,
  }) async {
    final source = File(sqlitePath);
    if (!source.existsSync()) {
      throw const DataRootMigrationException('找不到数据库文件');
    }
    final info = AppDatabase.inspect(source.path);
    if (!info.ok) {
      throw DataRootMigrationException('这不是可用的 SQLite 数据库：${info.integrity}');
    }
    if (info.version > AppDatabase.schemaVersion) {
      throw DataRootMigrationException(
        '这个库来自更新的版本（schema v${info.version}）',
      );
    }

    final rawName = (folderName ?? p.basenameWithoutExtension(source.path))
        .trim();
    final base = _safeFolderName(rawName.isEmpty ? '导入的库' : rawName);
    final parent = p.join(AppPaths.root.path, 'libraries');
    Directory(parent).createSync(recursive: true);
    final dir = _uniqueDirectory(parent, base);
    Directory(dir).createSync(recursive: true);
    source.copySync(AppPaths.libraryDatabaseFileIn(dir));
    await switchLibrary(dir);
    return dir;
  }

  /// 把另一个库合并进当前库：按 id 去重，同 id 保留 `updated_at` 较新的；
  /// 附件按 sha256 去重（字节只存一份），标签按名字合并。
  Future<LibraryMergeResult> mergeLibrary(String sqlitePath) async {
    final source = File(
      File(sqlitePath).existsSync()
          ? sqlitePath
          : p.join(sqlitePath, AppPaths.databaseFileName),
    );
    if (!source.existsSync()) {
      throw const DataRootMigrationException('找不到要合并的库');
    }
    if (p.equals(p.canonicalize(source.path), p.canonicalize(AppPaths.databaseFile))) {
      throw const DataRootMigrationException('不能把库和自己合并');
    }
    final info = AppDatabase.inspect(source.path);
    if (!info.ok) {
      throw DataRootMigrationException('要合并的库不可用：${info.integrity}');
    }
    if (info.version > AppDatabase.schemaVersion) {
      throw DataRootMigrationException(
        '要合并的库来自更新的版本（schema v${info.version}）',
      );
    }

    final blobsBefore = attachmentRepo.blobCount();
    final escaped = source.path.replaceAll("'", "''");
    var added = 0;
    var updated = 0;
    var attachmentsAdded = 0;
    db.raw.execute("ATTACH DATABASE '$escaped' AS src");
    try {
      db.raw.execute('BEGIN');
      // 附件字节：按 sha 去重
      db.raw.execute(
        'INSERT OR IGNORE INTO attachment_blobs (sha256, size, bytes) '
        'SELECT sha256, size, bytes FROM src.attachment_blobs',
      );
      // 新条目
      db.raw.execute(
        'INSERT INTO entries '
        '(id, title, body_md, entry_date, created_at, updated_at, rev, pinned, device_id, deleted_at) '
        'SELECT id, title, body_md, entry_date, created_at, updated_at, rev, pinned, device_id, deleted_at '
        'FROM src.entries WHERE id NOT IN (SELECT id FROM entries)',
      );
      added = db.raw.updatedRows;
      // 同 id 且源库更新 -> 覆盖
      db.raw.execute(
        'UPDATE entries SET '
        'title = (SELECT s.title FROM src.entries s WHERE s.id = entries.id), '
        'body_md = (SELECT s.body_md FROM src.entries s WHERE s.id = entries.id), '
        'entry_date = (SELECT s.entry_date FROM src.entries s WHERE s.id = entries.id), '
        'updated_at = (SELECT s.updated_at FROM src.entries s WHERE s.id = entries.id), '
        'rev = (SELECT s.rev FROM src.entries s WHERE s.id = entries.id), '
        'pinned = (SELECT s.pinned FROM src.entries s WHERE s.id = entries.id), '
        'device_id = (SELECT s.device_id FROM src.entries s WHERE s.id = entries.id), '
        'deleted_at = (SELECT s.deleted_at FROM src.entries s WHERE s.id = entries.id) '
        'WHERE id IN (SELECT s.id FROM src.entries s WHERE s.updated_at > entries.updated_at)',
      );
      updated = db.raw.updatedRows;
      // 附件索引：同 (entry_id, sha) 不重复插
      db.raw.execute(
        'INSERT INTO attachments (id, entry_id, sha256, filename, mime, size_bytes, created_at) '
        'SELECT s.id, s.entry_id, s.sha256, s.filename, s.mime, s.size_bytes, s.created_at '
        'FROM src.attachments s '
        'WHERE EXISTS (SELECT 1 FROM entries e WHERE e.id = s.entry_id) '
        'AND NOT EXISTS (SELECT 1 FROM attachments a '
        'WHERE a.entry_id = s.entry_id AND a.sha256 = s.sha256)',
      );
      attachmentsAdded = db.raw.updatedRows;
      // 标签：按名字合并，再把 entry_tags 映射到本库的 tag id
      db.raw.execute(
        'INSERT OR IGNORE INTO tags (id, name) SELECT id, name FROM src.tags',
      );
      db.raw.execute(
        'INSERT OR IGNORE INTO entry_tags (entry_id, tag_id) '
        'SELECT et.entry_id, '
        '(SELECT t2.id FROM tags t2 WHERE t2.name = '
        '(SELECT st.name FROM src.tags st WHERE st.id = et.tag_id)) '
        'FROM src.entry_tags et '
        'WHERE EXISTS (SELECT 1 FROM entries e WHERE e.id = et.entry_id) '
        'AND (SELECT st.name FROM src.tags st WHERE st.id = et.tag_id) IS NOT NULL',
      );
      db.raw.execute('COMMIT');
    } catch (error) {
      db.raw.execute('ROLLBACK');
      rethrow;
    } finally {
      db.raw.execute('DETACH DATABASE src');
    }

    await store.backfillFromFiles();
    await refresh();
    return LibraryMergeResult(
      added: added,
      updated: updated,
      attachmentsAdded: attachmentsAdded,
      blobsAdded: attachmentRepo.blobCount() - blobsBefore,
    );
  }

  static String _safeFolderName(String name) => name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');

  static String _uniqueDirectory(String parent, String base) {
    var candidate = p.join(parent, base);
    if (!Directory(candidate).existsSync()) return candidate;
    for (var index = 2; index < 1000; index++) {
      candidate = p.join(parent, '$base ($index)');
      if (!Directory(candidate).existsSync()) return candidate;
    }
    return p.join(parent, '$base-${DateTime.now().millisecondsSinceEpoch}');
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
    // 条目可能已被删除（回收站或别处）：不能拿内存里的旧对象导出「幽灵内容」。
    final fresh = entryRepo.findById(entry.id);
    if (fresh == null || fresh.isDeleted) {
      throw StateError('这篇日记已被删除，无法导出');
    }
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

  // ───────────────────────────── 回收站 ─────────────────────────────

  /// 恢复回收站里的全部日记；返回恢复的条数。
  Future<int> restoreAllDeleted() async {
    final list = deletedEntries();
    for (final entry in list) {
      entryRepo.restore(entry.id);
    }
    await refresh();
    notifyListeners();
    return list.length;
  }

  /// 清空回收站：逐条彻底删除并回收孤儿附件；返回删除的条数。
  Future<int> purgeAllDeleted() async {
    final list = deletedEntries();
    if (list.isEmpty) return 0;
    for (final entry in list) {
      attachmentRepo.deleteByEntry(entry.id);
      entryRepo.purge(entry.id);
      if (entry.id == _selected?.id) _selected = null;
    }
    await collectGarbage();
    await refresh();
    notifyListeners();
    return list.length;
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

  Map<String, String> _readEmojiCustom() {
    final raw = metaRepo.get('emoji_custom');
    if (raw == null || raw.trim().isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return <String, String>{
          for (final entry in decoded.entries)
            if ('${entry.value}'.trim().isNotEmpty)
              '${entry.key}'.trim(): '${entry.value}'.trim(),
        };
      }
    } on Object {
      // 坏数据当没有
    }
    return const <String, String>{};
  }

  void _saveEmojiCustom() {
    metaRepo.set(
      'emoji_custom',
      jsonEncode(_emojiCustom),
    );
  }

  /// 新增/覆盖一个表情映射。
  void setEmoji(String code, String value) {
    final key = code.trim().replaceAll(':', '').trim();
    final emoji = value.trim();
    if (key.isEmpty || emoji.isEmpty) return;
    _emojiCustom = <String, String>{..._emojiCustom, key: emoji};
    _saveEmojiCustom();
    notifyListeners();
  }

  /// 删除自定义映射（内置短代码恢复原值）。
  void removeEmoji(String code) {
    final key = code.trim().replaceAll(':', '').trim();
    if (!_emojiCustom.containsKey(key)) return;
    final next = <String, String>{..._emojiCustom}..remove(key);
    _emojiCustom = next;
    _saveEmojiCustom();
    notifyListeners();
  }

  void setUiFont(String font) {
    _uiFont = font.trim();
    metaRepo.set('ui_font', _uiFont);
    notifyListeners();
  }

  void setEditorFont(String font) {
    _editorFont = font.trim().isEmpty ? 'Cascadia Mono' : font.trim();
    metaRepo.set('editor_font', _editorFont);
    notifyListeners();
  }

  void setEditorFontSize(double size) {
    _editorFontSize = size.clamp(12, 28);
    metaRepo.set('editor_font_size', _editorFontSize.round().toString());
    notifyListeners();
  }

  @override
  void dispose() {
    _ragReindexTimer?.cancel();
    _rag?.close();
    _rag = null;
    _searchDebounce?.cancel();
    _saveDebounce?.cancel();
    super.dispose();
  }
}
