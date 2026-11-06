import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/formatters.dart';
import '../data/models.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/month_calendar.dart';
import '../ui/widgets.dart';
import 'entry_editor_page.dart';
import 'rag_page.dart';
import 'settings_page.dart';
import 'star_map/star_map_page.dart';
import 'trash_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  AppLifecycleListener? _lifecycleListener;
  AppState? _boundState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 关窗是「最后 800ms 输入」最容易丢的路径：Windows 直接关窗不会走 dispose，
    // onExitRequested 会在进程退出前给我们一次强制落库的机会。
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        final state = mounted ? AppScope.of(context) : null;
        await state?.flushNow();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (identical(_boundState, state)) return;
    _boundState?.removeListener(_onStateChanged);
    _boundState = state;
    state.addListener(_onStateChanged);
  }

  /// 没有页面上下文的操作（比如拖拽导入）通过一次性提示反馈给用户。
  void _onStateChanged() {
    final state = _boundState;
    if (state == null) return;
    final message = state.takeToast();
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
        );
    });
  }

  @override
  void dispose() {
    _boundState?.removeListener(_onStateChanged);
    _lifecycleListener?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (!mounted) return;
    // 窗口失焦/最小化/退出时强制落库，配合 800ms 防抖形成双保险。
    if (lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      AppScope.of(context).flushNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (state.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Column(
          children: <Widget>[
            if (state.dataRootNotice != null) _DataRootNoticeBar(state: state),
            Expanded(
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: _listPaneWidth(context),
                    child: _buildListPane(context, state),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildContentPane(context, state)),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _StatusBar(state: state),
    );
  }

  /// 列表栏宽度：窄窗口下收缩，避免编辑区被挤到不可用（最小 240，最大 360）。
  double _listPaneWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (width * 0.26).clamp(240.0, 360.0);
  }

  /// 全局快捷键。用 Focus.onKeyEvent 显式处理，而不是 CallbackShortcuts：
  /// 后者在无头测试与部分桌面场景下收不到组合键（Ctrl+N 不触发）。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (keyboard.isControlPressed) {
      if (key == LogicalKeyboardKey.keyN) {
        AppScope.of(context).createEntry();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyS) {
        AppScope.of(context).flushNow();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyF) {
        _searchFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      _searchFocus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ───────────────────────────── 左栏 ─────────────────────────────

  Widget _buildListPane(BuildContext context, AppState state) {
    return Column(
      children: <Widget>[
        _buildHeader(context, state),
        const Divider(height: 1),
        MonthCalendar(
          month: state.calendarMonth,
          selectedDate: state.selectedDate,
          markedDates: state.markedDates,
          today: DateTime.now(),
          onSelect: (day) => state.selectDay(day),
          onMonthChanged: state.showMonth,
        ),
        const Divider(height: 1),
        Expanded(child: _buildEntryList(context, state)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      child: Column(
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              FilledButton.icon(
                onPressed: () => state.createEntry(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建日记'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
              ),
              _HeaderIconButton(
                tooltip: 'RAG（问答 / 日报 / 档案）',
                onPressed: _openRag,
                icon: const Icon(Icons.auto_awesome_outlined),
              ),
              _HeaderIconButton(
                tooltip: '星图',
                onPressed: _openStarMap,
                icon: const Icon(Icons.hub_outlined),
              ),
              _HeaderIconButton(
                tooltip: state.trashCount > 0
                    ? '回收站（${state.trashCount}）'
                    : '回收站',
                onPressed: () => _openPage(const TrashPage()),
                icon: Badge(
                  isLabelVisible: state.trashCount > 0,
                  label: Text('${state.trashCount}'),
                  child: const Icon(Icons.delete_outline),
                ),
              ),
              _HeaderIconButton(
                tooltip: '设置',
                onPressed: () => _openPage(const SettingsPage()),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            onChanged: state.setQuery,
            onSubmitted: state.rememberQuery,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索标题、正文或标签（Ctrl+F）',
              hintStyle: theme.textTheme.bodySmall,
              prefixIcon: const Icon(Icons.search, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIcon: state.query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      iconSize: 16,
                      onPressed: () {
                        _searchController.clear();
                        state.setQuery('');
                      },
                      icon: const Icon(Icons.close),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.55,
              ),
              contentPadding: const EdgeInsets.symmetric(
                vertical: 10,
                horizontal: 8,
              ),
            ),
          ),
          if (state.allTags.isNotEmpty || state.recentQueries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _buildFilterBar(context, state),
            ),
        ],
      ),
    );
  }

  /// 搜索框下面的筛选条：标签筛选 + 最近搜索。
  Widget _buildFilterBar(BuildContext context, AppState state) {
    final theme = Theme.of(context);
    final tags = state.allTags;
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                _FilterChip(
                  label: '全部',
                  selected: state.tagFilter == null,
                  onTap: () => state.setTagFilter(null),
                ),
                for (final tag in tags)
                  _FilterChip(
                    label: tag,
                    selected: state.tagFilter == tag,
                    onTap: () => state.setTagFilter(
                      state.tagFilter == tag ? null : tag,
                    ),
                  ),
              ],
            ),
          ),
          if (state.recentQueries.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: '最近搜索',
              iconSize: 18,
              padding: EdgeInsets.zero,
              onSelected: (value) {
                if (value == '__clear__') {
                  state.clearQueryHistory();
                  return;
                }
                _searchController.text = value;
                state.setQuery(value);
              },
              itemBuilder: (menuContext) => <PopupMenuEntry<String>>[
                for (final query in state.recentQueries)
                  PopupMenuItem<String>(value: query, child: Text(query)),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: '__clear__',
                  child: Text('清空搜索历史'),
                ),
              ],
              icon: Icon(
                Icons.history,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEntryList(BuildContext context, AppState state) {
    final entries = state.entries;
    if (entries.isEmpty) {
      return EmptyState(
        icon: state.query.isEmpty ? Icons.menu_book_outlined : Icons.search_off,
        title: state.query.isEmpty ? '还没有日记' : '没有匹配的日记',
        description: state.query.isEmpty ? '按 Ctrl+N 开始写第一篇' : '换个关键词试试',
        action: state.query.isEmpty
            ? FilledButton.icon(
                onPressed: () => state.createEntry(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建日记'),
              )
            : null,
      );
    }
    // 按日期分组：插入 "日期 -> 条目" 的扁平序列，交给 ListView.builder 惰性构建。
    final items = <_ListItem>[];
    String? lastDate;
    for (final entry in entries) {
      final date = formatDate(entry.entryDate);
      if (date != lastDate) {
        items.add(_ListItem.header(date));
        lastDate = date;
      }
      items.add(_ListItem.entry(entry));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item.dateHeader != null) {
          return SectionLabel(item.dateHeader!);
        }
        final entry = item.entry!;
        return EntryListTile(
          entry: entry,
          selected: state.selected?.id == entry.id,
          attachmentCount: state.attachmentCountOf(entry.id),
          tags: state.tagsOf(entry.id),
          query: state.query,
          onTap: () => state.select(entry),
          onMenu: (position) => _showEntryMenu(context, state, entry, position),
        );
      },
    );
  }

  Future<void> _showEntryMenu(
    BuildContext context,
    AppState state,
    Entry entry,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'pin',
          child: Text(entry.pinned ? '取消置顶' : '置顶'),
        ),
        const PopupMenuItem<String>(value: 'export', child: Text('导出为 .md')),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: 'delete', child: Text('移到回收站')),
      ],
    );
    if (selected == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (selected == 'pin') {
      await state.togglePin(entry);
    } else if (selected == 'export') {
      final path = await state.exportCurrent(entry);
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text('已导出到 $path')));
      }
    } else if (selected == 'delete') {
      await state.deleteEntry(entry);
    }
  }

  // ───────────────────────────── 右栏 ─────────────────────────────

  Widget _buildContentPane(BuildContext context, AppState state) {
    final selected = state.selected;
    if (selected == null) {
      return const EmptyState(
        icon: Icons.edit_note,
        title: '选择一篇日记，或新建',
        description: '内容输入后自动保存为 Markdown，可随时导出 .md 文件',
      );
    }
    return EntryEditorPage(
      key: ValueKey<String>(selected.id),
      state: state,
      entry: selected,
    );
  }

  void _openPage(Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (context) => page));
  }

  /// RAG 界面里点日记命中 -> 带着那篇回来并选中。
  Future<void> _openRag() async {
    final entry = await Navigator.of(context).push<Entry>(
      MaterialPageRoute<Entry>(builder: (context) => const RagPage()),
    );
    if (!mounted || entry == null) return;
    await AppScope.of(context).select(entry);
  }

  /// 星图里点日记星 -> 带着那篇回来并选中，直接进入编辑。
  Future<void> _openStarMap() async {
    final entry = await Navigator.of(context).push<Entry>(
      MaterialPageRoute<Entry>(builder: (context) => const StarMapPage()),
    );
    if (!mounted || entry == null) return;
    await AppScope.of(context).select(entry);
  }
}

class _ListItem {
  _ListItem.header(this.dateHeader) : entry = null;

  _ListItem.entry(this.entry) : dateHeader = null;

  final String? dateHeader;
  final Entry? entry;
}

/// 左栏头部的小图标按钮：240 宽的窄栏里「新建 + 星图 + 回收站 + 设置」必须挤得下，
/// 默认 IconButton 的 40~48 点击区会把这一行撑溢出，这里固定 32x32。
class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      iconSize: 20,
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        maximumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 数据没能放在默认目录时的常驻提示：不能让用户以为日记丢了。
class _DataRootNoticeBar extends StatelessWidget {
  const _DataRootNoticeBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: scheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '默认数据目录不可写，本次数据存放在：${state.dataRootPath}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => state.openInSystem(state.dataRootPath),
              child: const Text('打开目录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 0.6),
        ),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '${state.entries.length} 篇',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (state.query.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            Text(
              '搜索：${state.query}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const Spacer(),
          SaveIndicator(
            status: state.status,
            error: state.lastError,
            onRetry: () => state.flushNow(),
          ),
          const SizedBox(width: 14),
          Text(
            'v1.1.1',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索框下面的一枚小筛选标签。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}