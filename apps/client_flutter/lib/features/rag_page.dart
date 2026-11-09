import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rag/answer.dart';
import '../rag/rag_service.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/markdown_view.dart';
import '../ui/widgets.dart';

/// RAG 独立界面（2.0.7）：问答 / 日报 / 档案。
///
/// 问答目前只做检索（向量 + 关键词）并展示命中片段，点日记命中会返回主界面打开它；
/// 生成式回答在 2.0.2 接入。
class RagPage extends StatefulWidget {
  const RagPage({super.key});

  @override
  State<RagPage> createState() => _RagPageState();
}

class _RagPageState extends State<RagPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final TextEditingController _query = TextEditingController();

  final List<_ChatMessage> _messages = <_ChatMessage>[];
  List<AnswerTurn> _turns = const <AnswerTurn>[];
  bool _chatBusy = false;
  StreamSubscription<String>? _answerSubscription;

  int _chunkCount = 0;
  String _indexedAt = '';
  int? _indexDone;
  int? _indexTotal;
  bool _reindexing = false;

  List<DateTime> _reportDates = const <DateTime>[];
  DateTime? _selectedReport;
  String? _reportMarkdown;
  bool _reportsLoading = true;
  bool _reportBusy = false;

  String? _soul;
  bool _soulBusy = false;

  @override
  void initState() {
    super.initState();
    // AppScope 要等第一帧之后才能安全读取。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadReports();
      _loadSoul();
      _loadStats();
    });
  }

  @override
  void dispose() {
    _answerSubscription?.cancel();
    _tabs.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('RAG'),
        centerTitle: false,
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'reindex') _reindex(state);
              if (value == 'folder') state.openInSystem(state.libraryPath);
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'reindex', child: Text('重建索引')),
              PopupMenuItem<String>(value: 'folder', child: Text('打开库目录')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const <Widget>[
            Tab(text: '问答'),
            Tab(text: '日报'),
            Tab(text: '档案'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          _buildAskTab(context, state),
          _buildReportsTab(context, state),
          _buildSoulTab(context, state),
        ],
      ),
    );
  }

  // ───────────────────────────── 问答 ─────────────────────────────

  Widget _buildAskTab(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _chunkCount == 0
                      ? '还没有索引：点右上角「重建索引」，或等后台每日整理'
                      : '索引：$_chunkCount 个切片 · 向量 ${state.ragStats.model.isEmpty ? '未知' : state.ragStats.model}'
                            '${_indexedAt.isEmpty ? '' : ' · 更新于 ${_indexedAt.replaceFirst('T', ' ').split('.').first}'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                state.cloudEnabled
                    ? '云端 ${state.ragSettings.cloudModel}'
                    : '本地 ${state.ragSettings.askModel}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_messages.isNotEmpty)
                TextButton(
                  onPressed: _newChat,
                  child: const Text('新对话'),
                ),
              if (_chatBusy)
                TextButton(
                  onPressed: _stopAnswering,
                  child: const Text('停止'),
                ),
            ],
          ),
        ),
        if (_indexTotal != null && _reindexing)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: LinearProgressIndicator(
              value: _indexTotal == 0 ? null : _indexDone! / _indexTotal!,
              minHeight: 3,
            ),
          ),
        Expanded(
          child: _messages.isEmpty
              ? const EmptyState(
                  icon: Icons.auto_awesome_outlined,
                  title: '和日记对话',
                  description: '直接提问：系统会先检索日记与附件，再让模型带 [日期-标题] 引用回答；可以继续追问。',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) =>
                      _bubble(context, state, _messages[index]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('rag-chat-input'),
                  controller: _query,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(state),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '问点什么，比如「去年在杭州吃了什么」',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('rag-send'),
                onPressed: _chatBusy ? null : () => _send(state),
                icon: const Icon(Icons.send, size: 18),
                label: const Text('发送'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bubble(BuildContext context, AppState state, _ChatMessage message) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: EdgeInsets.fromLTRB(
          isUser ? 80 : 4,
          6,
          isUser ? 4 : 80,
          6,
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (!isUser) ...<Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.auto_awesome,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Text('回答', style: theme.textTheme.labelSmall),
                  if (message.queries.length > 1) ...<Widget>[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '检索词：${message.queries.join(' / ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
            ],
            SelectableText(
              message.text.isEmpty
                  ? (message.failed ? '处理失败' : '正在检索…')
                  : message.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: message.failed ? theme.colorScheme.error : null,
              ),
            ),
            if (message.sources.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final hit in message.sources.take(6))
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        hit.isAttachment
                            ? Icons.attach_file
                            : Icons.menu_book_outlined,
                        size: 14,
                      ),
                      label: Text(
                        '${_date(hit.date)} ${hit.label}',
                        style: theme.textTheme.labelSmall,
                      ),
                      onPressed: () => _openHit(state, hit),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _send(AppState state) async {
    final question = _query.text.trim();
    if (question.isEmpty || _chatBusy) return;
    _query.clear();
    final history = _turns.length <= 6
        ? _turns
        : _turns.sublist(_turns.length - 6);
    setState(() {
      _chatBusy = true;
      _messages.add(_ChatMessage.user(question));
      _messages.add(_ChatMessage.assistant());
    });
    try {
      final reply = await state.chatAsk(question, history: history);
      if (!mounted) return;
      setState(() {
        final last = _messages.last;
        last.sources = reply.sources;
        last.queries = reply.queries;
      });
      _answerSubscription = reply.answer.listen(
        (chunk) {
          if (!mounted) return;
          setState(() => _messages.last.text += chunk);
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            final last = _messages.last;
            last
              ..failed = true
              ..streaming = false
              ..text = '没答出来：$error';
            _chatBusy = false;
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            final last = _messages.last;
            last.streaming = false;
            _chatBusy = false;
            if (!last.failed && last.text.trim().isNotEmpty) {
              _turns = <AnswerTurn>[
                ..._turns,
                AnswerTurn(question: question, answer: last.text),
              ];
            }
          });
        },
        cancelOnError: true,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        final last = _messages.last;
        last
          ..failed = true
          ..streaming = false
          ..text = '没答出来：$error';
        _chatBusy = false;
      });
    }
  }

  void _stopAnswering() {
    _answerSubscription?.cancel();
    if (!mounted) return;
    setState(() {
      if (_messages.isNotEmpty) _messages.last.streaming = false;
      _chatBusy = false;
    });
  }

  void _newChat() {
    _answerSubscription?.cancel();
    setState(() {
      _messages.clear();
      _turns = const <AnswerTurn>[];
      _chatBusy = false;
    });
  }
  Future<void> _loadStats() async {
    try {
      final stats = AppScope.of(context).ragStats;
      if (!mounted) return;
      setState(() {
        _chunkCount = stats.chunks;
        _indexedAt = stats.indexedAt;
      });
    } on Object {
      // 索引库还没建好：忽略
    }
  }

  Future<void> _openHit(AppState state, RagHit hit) async {
    if (hit.isAttachment) {
      final attachment = state.attachmentById(hit.attachmentId);
      final path = attachment == null ? null : state.localPathOf(attachment);
      if (path != null) {
        await state.openInSystem(path);
        return;
      }
    }
    final entryId = hit.entryId;
    if (entryId == null) return;
    final entry = state.entryRepo.findById(entryId);
    if (entry == null || !mounted) return;
    Navigator.of(context).pop(entry);
  }

  // ───────────────────────────── 日报 ─────────────────────────────

  Widget _buildReportsTab(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _reportsLoading
                      ? '正在读取日报…'
                      : '共 ${_reportDates.length} 篇日报（没有记录的日期也会有一篇）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _reportBusy ? null : () => _backfill(state),
                icon: const Icon(Icons.playlist_add_check, size: 18),
                label: const Text('补全缺失'),
              ),
              TextButton.icon(
                onPressed: _reportBusy ? null : () => _generateToday(state),
                icon: const Icon(Icons.today, size: 18),
                label: const Text('重新生成今天'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _reportDates.isEmpty
              ? EmptyState(
                  icon: Icons.event_note_outlined,
                  title: _reportsLoading ? '读取中…' : '还没有日报',
                  description: '点「补全缺失」按日记生成到昨天；今天可以单独生成',
                )
              : Row(
                  children: <Widget>[
                    SizedBox(
                      width: 220,
                      child: ListView.builder(
                        itemCount: _reportDates.length,
                        itemBuilder: (context, index) {
                          final date = _reportDates[index];
                          final selected =
                              _selectedReport != null &&
                              _sameDay(_selectedReport!, date);
                          return ListTile(
                            dense: true,
                            selected: selected,
                            title: Text(_date(date)),
                            trailing: date == _today()
                                ? const Icon(Icons.edit_note, size: 16)
                                : null,
                            onTap: () => _selectReport(state, date),
                          );
                        },
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _reportMarkdown == null
                          ? const EmptyState(
                              icon: Icons.description_outlined,
                              title: '选一篇日报',
                              description: '左边选日期，右边看内容',
                            )
                          : SingleChildScrollView(
                              child: MarkdownView(
                                data: _reportMarkdown!,
                                resolveLocalPath: (_) => null,
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  16,
                                  24,
                                  48,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _loadReports() async {
    final state = AppScope.of(context);
    setState(() => _reportsLoading = true);
    try {
      final dates = state.ragReportDates();
      if (!mounted) return;
      setState(() {
        _reportDates = dates;
        _reportsLoading = false;
      });
      if (dates.isNotEmpty) {
        await _selectReport(state, _selectedReport ?? dates.first);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _reportsLoading = false);
      _snack(context, '读取日报失败：$error');
    }
  }

  Future<void> _selectReport(AppState state, DateTime date) async {
    final markdown = state.ragReportMarkdown(date);
    if (!mounted) return;
    setState(() {
      _selectedReport = date;
      _reportMarkdown = markdown;
    });
  }

  Future<void> _backfill(AppState state) async {
    setState(() => _reportBusy = true);
    try {
      final run = await state.backfillReports();
      if (!mounted) return;
      _snack(context, run.toString());
      await _loadReports();
    } on Object catch (error) {
      if (mounted) _snack(context, '补全失败：$error');
    } finally {
      if (mounted) setState(() => _reportBusy = false);
    }
  }

  Future<void> _generateToday(AppState state) async {
    setState(() => _reportBusy = true);
    try {
      final today = DateTime.now();
      final result = await state.generateReport(today, force: true);
      if (!mounted) return;
      _snack(
        context,
        result.skipped ? '今天已经有日报了' : '已生成 ${_date(today)} 的日报',
      );
      await _loadReports();
      await _selectReport(state, today);
    } on Object catch (error) {
      if (mounted) _snack(context, '生成失败：$error');
    } finally {
      if (mounted) setState(() => _reportBusy = false);
    }
  }

  // ───────────────────────────── 档案 ─────────────────────────────

  Widget _buildSoulTab(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    if (_soul == null) {
      return EmptyState(
        icon: Icons.psychology_outlined,
        title: '还没有灵魂档案',
        description: '点「重新生成」让模型把整个库概括成一份 ≤ 8 KB 的档案',
        action: FilledButton.icon(
          onPressed: _soulBusy ? null : () => _regenerateSoul(state),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重新生成'),
        ),
      );
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'rag/soul.md · ${_soul!.length} 字符 · 可以贴给任何大模型当上下文',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _soulBusy ? null : () => _regenerateSoul(state),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新生成'),
              ),
              TextButton.icon(
                onPressed: () => _copySoul(),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制全文'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            child: MarkdownView(
              data: _soul!,
              resolveLocalPath: (_) => null,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _loadSoul() async {
    final soul = AppScope.of(context).soulMarkdown();
    if (!mounted) return;
    setState(() => _soul = soul);
  }

  Future<void> _regenerateSoul(AppState state) async {
    setState(() => _soulBusy = true);
    try {
      final report = await state.regenerateSoul();
      if (!mounted) return;
      _snack(context, report.toString());
      await _loadSoul();
    } on Object catch (error) {
      if (mounted) _snack(context, '生成档案失败：$error');
    } finally {
      if (mounted) setState(() => _soulBusy = false);
    }
  }

  Future<void> _copySoul() async {
    final text = _soul;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _snack(context, '已复制 soul.md');
  }

  // ───────────────────────────── 工具 ─────────────────────────────

  Future<void> _reindex(AppState state) async {
    if (_reindexing) return;
    setState(() {
      _reindexing = true;
      _indexDone = 0;
      _indexTotal = null;
    });
    try {
      final report = await state.reindexRag(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _indexDone = progress.done;
            _indexTotal = progress.total;
          });
        },
      );
      if (!mounted) return;
      _snack(context, report.toString());
      await _loadStats();
    } on Object catch (error) {
      if (mounted) _snack(context, '重建索引失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _reindexing = false;
          _indexDone = null;
          _indexTotal = null;
        });
      }
    }
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  static String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}
/// 一条对话消息（用户 / 助手）。
class _ChatMessage {
  _ChatMessage.user(this.text)
    : isUser = true,
      sources = const <RagHit>[],
      queries = const <String>[],
      streaming = false,
      failed = false;

  _ChatMessage.assistant()
    : isUser = false,
      text = '',
      sources = const <RagHit>[],
      queries = const <String>[],
      streaming = true,
      failed = false;

  final bool isUser;
  String text;
  List<RagHit> sources;
  List<String> queries;
  bool streaming;
  bool failed;
}