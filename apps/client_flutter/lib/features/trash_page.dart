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
    setState(() => _entries = state.deletedEntries());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('回收站'), centerTitle: false),
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
