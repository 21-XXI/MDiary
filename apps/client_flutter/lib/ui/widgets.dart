import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../data/models.dart';
import '../state/app_state.dart';

/// 左侧列表项：日期 + 标题 + 摘要 + 附件数/置顶标记。
class EntryListTile extends StatelessWidget {
  const EntryListTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    this.attachmentCount = 0,
    this.tags = const <String>[],
    this.onMenu,
  });

  final Entry entry;
  final bool selected;
  final VoidCallback onTap;
  final int attachmentCount;

  /// 日记标签（只展示前两个，避免把列表项撑高）。
  final List<String> tags;

  /// 右键/长按菜单（置顶、删除等由列表页提供）。
  final void Function(Offset globalPosition)? onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = entry.title.trim().isEmpty
        ? deriveTitleFromBody(entry.bodyMd)
        : entry.title.trim();
    final preview = _previewOf(entry.bodyMd);
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.55)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (entry.pinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.push_pin,
                        size: 13,
                        color: scheme.primary,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (attachmentCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.attach_file,
                            size: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          Text(
                            '$attachmentCount',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (onMenu != null)
                    GestureDetector(
                      onSecondaryTapDown: (details) =>
                          onMenu!(details.globalPosition),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.more_horiz, size: 16),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                preview.isEmpty ? '（空白）' : preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (tags.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final tag in tags.take(2))
                      Text(
                        '#$tag',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.tertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (tags.length > 2)
                      Text(
                        '+${tags.length - 2}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Text(
                    formatRelative(entry.updatedAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatDate(entry.entryDate),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _previewOf(String body) {
    return body
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '[图片]')
        .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
        .replaceAll(RegExp(r'[#>*_`~]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

/// 保存状态指示（右上角）。保存失败时可点击重试（pending 内容仍在内存里）。
class SaveIndicator extends StatelessWidget {
  const SaveIndicator({
    super.key,
    required this.status,
    this.error,
    this.onRetry,
  });

  final SaveStatus status;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String label, Color color) = switch (status) {
      SaveStatus.idle => (
        Icons.circle_outlined,
        '就绪',
        theme.colorScheme.onSurfaceVariant,
      ),
      SaveStatus.dirty => (
        Icons.edit_outlined,
        '编辑中…',
        theme.colorScheme.onSurfaceVariant,
      ),
      SaveStatus.saving => (
        Icons.cloud_upload_outlined,
        '保存中…',
        theme.colorScheme.onSurfaceVariant,
      ),
      SaveStatus.saved => (
        Icons.check_circle_outline,
        '已保存',
        Colors.green.shade600,
      ),
      SaveStatus.error => (
        Icons.error_outline,
        '保存失败',
        theme.colorScheme.error,
      ),
    };
    final canRetry = status == SaveStatus.error && onRetry != null;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          canRetry ? '$label · 点此重试' : label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
    return Tooltip(
      message: status == SaveStatus.error ? (error ?? '保存失败；点击重试') : label,
      child: canRetry
          ? InkWell(
              onTap: onRetry,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: content,
              ),
            )
          : content,
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 左栏加了日历后，小窗口里留给空状态的高度可能不够；可滚动就不会溢出。
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            if (description != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
