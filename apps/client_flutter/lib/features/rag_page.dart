import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  List<RagHit> _hits = const <RagHit>[];
  bool _searching = false;
  bool _searched = false;
  String _answer = '';
  bool _answering = false;
  StreamSubscription<String>? _answerSubscription;

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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(state),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '问点什么，比如「去年在杭州吃了什么」',
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _searching ? null : () => _search(state),
                icon: _searching
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search, size: 18),
                label: const Text('检索'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _answering || _hits.isEmpty
                    ? null
                    : () => _generateAnswer(state),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: Text(_answering ? '生成中…' : '生成回答'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '先用「检索」看命中的日记与附件；生成式回答在 2.0.2 接入。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (_answer.isNotEmpty || _answering)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text('回答', style: theme.textTheme.labelLarge),
                        const Spacer(),
                        if (_answering)
                          TextButton(
                            onPressed: _stopAnswering,
                            child: const Text('停止'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      _answer.isEmpty ? '正在生成…' : _answer,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _hits.isEmpty
              ? EmptyState(
                  icon: Icons.auto_awesome_outlined,
                  title: _searched ? '没有命中' : '还没有提问',
                  description: _searched
                      ? '换个说法，或先点右上角「重建索引」'
                      : '索引由后台每日整理；也可以先重建一次',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _hits.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final hit = _hits[index];
                    return ListTile(
                      leading: Icon(
                        hit.isAttachment
                            ? Icons.attach_file
                            : Icons.menu_book_outlined,
                        size: 20,
                      ),
                      title: Text(
                        '${_date(hit.date)}  ${hit.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        hit.snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: Text(
                        hit.score.toStringAsFixed(3),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () => _openHit(state, hit),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _search(AppState state) async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _searched = true;
    });
    try {
      final hits = await state.ragSearch(query, k: 10);
      if (!mounted) return;
      setState(() => _hits = hits);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _hits = const <RagHit>[]);
      _snack(context, '检索失败：$error');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _generateAnswer(AppState state) {
    final query = _query.text.trim();
    if (query.isEmpty || _hits.isEmpty) return;
    _answerSubscription?.cancel();
    setState(() {
      _answer = '';
      _answering = true;
    });
    _answerSubscription = state.streamAnswer(query, _hits).listen(
      (chunk) {
        if (!mounted) return;
        setState(() => _answer += chunk);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _answering = false);
        _snack(context, '生成失败：$error');
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _answering = false);
      },
      cancelOnError: true,
    );
  }

  void _stopAnswering() {
    _answerSubscription?.cancel();
    setState(() => _answering = false);
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
    _snack(context, '正在重建索引…');
    try {
      final report = await state.reindexRag();
      if (!mounted) return;
      _snack(context, report.toString());
    } on Object catch (error) {
      if (mounted) _snack(context, '重建索引失败：$error');
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
