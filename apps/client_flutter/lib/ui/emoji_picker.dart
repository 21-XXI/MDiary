import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// 打开表情面板；返回选中的短代码（不含冒号），取消返回 null。
Future<String?> showEmojiPicker(
  BuildContext context, {
  required AppState state,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _EmojiDialog(state: state),
  );
}

class _EmojiDialog extends StatefulWidget {
  const _EmojiDialog({required this.state});

  final AppState state;

  @override
  State<_EmojiDialog> createState() => _EmojiDialogState();
}

class _EmojiDialogState extends State<_EmojiDialog> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('表情'),
      content: SizedBox(
        width: 700,
        height: 540,
        child: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final query = _search.text.trim().toLowerCase();
            final entries = widget.state.emojiMap.entries
                .where(
                  (entry) =>
                      query.isEmpty ||
                      entry.key.toLowerCase().contains(query) ||
                      entry.value.contains(query),
                )
                .toList()
              ..sort((a, b) => a.key.compareTo(b.key));
            final custom = widget.state.emojiCustom;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: '搜索短代码或表情，比如 smile / 微笑',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: () => _addCustom(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('自定义'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '插入的是短代码（如 :smile:），预览时显示为表情；自定义会覆盖内置映射。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('没有匹配的表情'))
                      : GridView.extent(
                          maxCrossAxisExtent: 140,
                          childAspectRatio: 2.6,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                          children: <Widget>[
                            for (final entry in entries)
                              _EmojiTile(
                                code: entry.key,
                                emoji: entry.value,
                                overridden: custom.containsKey(entry.key),
                                onTap: () =>
                                    Navigator.of(context).pop(entry.key),
                              ),
                          ],
                        ),
                ),
                if (custom.isNotEmpty) ...<Widget>[
                  const Divider(height: 16),
                  Text(
                    '自定义（${custom.length}）',
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final entry in custom.entries)
                        InputChip(
                          label: Text('${entry.value} :${entry.key}:'),
                          onPressed: () =>
                              Navigator.of(context).pop(entry.key),
                          onDeleted: () => widget.state.removeEmoji(entry.key),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _addCustom(BuildContext context) async {
    final codeController = TextEditingController();
    final emojiController = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('自定义表情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: codeController,
              decoration: const InputDecoration(
                labelText: '短代码（不含冒号）',
                hintText: '例如 cat2 或 猫咪',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: emojiController,
              decoration: const InputDecoration(
                labelText: '显示内容',
                hintText: '粘贴一个 emoji，或任意短文字',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              widget.state.setEmoji(
                codeController.text,
                emojiController.text,
              );
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    codeController.dispose();
    emojiController.dispose();
    if (added == true && mounted) setState(() {});
  }
}

class _EmojiTile extends StatelessWidget {
  const _EmojiTile({
    required this.code,
    required this.emoji,
    required this.overridden,
    required this.onTap,
  });

  final String code;
  final String emoji;
  final bool overridden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: overridden
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: overridden ? 1.2 : 0.6,
          ),
        ),
        child: Row(
          children: <Widget>[
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ':$code:',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
