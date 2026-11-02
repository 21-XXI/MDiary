import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Markdown 预览。附件图片走本地内容寻址库；找不到时给出可见的占位提示，
/// 而不是静默空白（对应验收 D2/E1）。
class MarkdownView extends StatelessWidget {
  const MarkdownView({
    super.key,
    required this.data,
    required this.resolveLocalPath,
    this.onOpenLink,
    this.padding = const EdgeInsets.fromLTRB(24, 16, 24, 64),
  });

  final String data;

  /// `assets/<sha>.<ext>` -> 本地绝对路径；返回 null 表示缺失。
  final String? Function(String reference) resolveLocalPath;
  final void Function(String reference)? onOpenLink;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (data.trim().isEmpty) {
      return Center(
        child: Text(
          '还没有内容',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      padding: padding,
      child: MarkdownBody(
        data: data,
        selectable: true,
        styleSheet: _buildStyleSheet(context),
        imageBuilder: (uri, title, alt) {
          final reference = uri.toString();
          final path = resolveLocalPath(reference);
          if (path == null) {
            return _MissingAttachment(
              label: alt?.isNotEmpty == true ? alt! : reference,
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) =>
                    _MissingAttachment(label: reference),
              ),
            ),
          );
        },
        onTapLink: (text, href, title) {
          if (href != null && onOpenLink != null) onOpenLink!(href);
        },
      ),
    );
  }

  MarkdownStyleSheet _buildStyleSheet(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = MarkdownStyleSheet.fromTheme(theme);
    return base.copyWith(
      p: theme.textTheme.bodyLarge?.copyWith(height: 1.75, fontSize: 15.5),
      h1: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.5,
      ),
      h2: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.5,
      ),
      h3: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
      blockquote: theme.textTheme.bodyMedium?.copyWith(
        color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.75),
        height: 1.7,
      ),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      code: TextStyle(
        fontFamily: 'Cascadia Mono',
        fontFamilyFallback: const <String>['Consolas', 'Microsoft YaHei'],
        fontSize: 13.5,
        backgroundColor: scheme.surfaceContainerHighest,
        color: scheme.onSurface,
      ),
      codeblockDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      listBullet: theme.textTheme.bodyLarge,
      tableBorder: TableBorder.all(color: scheme.outlineVariant, width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      a: TextStyle(color: scheme.primary, decoration: TextDecoration.underline),
    );
  }
}

class _MissingAttachment extends StatelessWidget {
  const _MissingAttachment({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.broken_image_outlined,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '附件缺失：$label',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
