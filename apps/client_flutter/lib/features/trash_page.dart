import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../data/models.dart';
import '../state/app_scope.dart';
import '../ui/widgets.dart';

class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<Entry> _entries = const <Entry>[];
  bool _loaded = false;
  bool _byDeletedAt = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  void _reload() {
    final state = AppScope.of(context);
    setState(
      () => _entries = state.deletedEntries(byDeletedAt: _byDeletedAt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        centerTitle: false,
        actions: <Widget>[
          if (_entries.isNotEmpty) ...<Widget>[
            PopupMenuButton<bool>(
              tooltip: '排序',
              icon: const Icon(Icons.sort, size: 20),
              onSelected: (byDeletedAt) {
                setState(() => _byDeletedAt = byDeletedAt);
                _reload();
              },
              itemBuilder: (menuContext) => const <PopupMenuEntry<bool>>[
                PopupMenuItem<bool>(value: true, child: Text('按删除时间')),
                PopupMenuItem<bool>(value: false, child: Text('按日记日期')),
              ],
            ),
            TextButton.icon(
              onPressed: _confirmRestoreAll,
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('全部恢复'),
            ),
            TextButton.icon(
              onPressed: _confirmPurgeAll,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空'),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: _entries.isEmpty
          ? const EmptyState(
              icon: Icons.delete_outline,
              title: '回收站是空的',
              description: '删除的日记会先放到这里，可随时恢复',
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _entries.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                final title = entry.title.trim().isEmpty
                    ? deriveTitleFromBody(entry.bodyMd)
                    : entry.title;
                final attachmentCount = state.attachmentCountOf(entry.id);
                final deletedAt = entry.deletedAt;
                return ListTile(
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '删除于 ${deletedAt == null ? '-' : formatDateTime(deletedAt)}'
                    '${attachmentCount > 0 ? ' · $attachmentCount 个附件' : ''}',
                    style: theme.textTheme.labelSmall,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextButton.icon(
                        onPressed: () async {
                          await AppScope.of(context).restoreEntry(entry);
                          if (mounted) _reload();
                        },
                        icon: const Icon(Icons.restore, size: 16),
                        label: const Text('恢复'),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: () => _confirmPurge(entry, title),
                        icon: const Icon(Icons.delete_forever, size: 16),
                        label: const Text('彻底删除'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _confirmRestoreAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('全部恢复？'),
        content: Text('把回收站里的 ${_entries.length} 篇日记恢复到原来的日期。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final restored = await AppScope.of(context).restoreAllDeleted();
    if (!mounted) return;
    _reload();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已恢复 $restored 篇日记')));
  }

  Future<void> _confirmPurgeAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空回收站？'),
        content: Text('将永久删除回收站里的 ${_entries.length} 篇日记及其附件，无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await AppScope.of(context).purgeAllDeleted();
    if (!mounted) return;
    _reload();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已清除 $removed 篇日记'),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  Future<void> _confirmPurge(Entry entry, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('彻底删除？'),
        content: Text('「$title」及其附件将被永久删除，无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AppScope.of(context).purgeEntry(entry);
    if (mounted) _reload();
  }
}
