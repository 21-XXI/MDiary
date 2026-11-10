import 'dart:io';

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/emoji.dart';
import 'markdown_extras.dart';

/// Markdown 预览。附件图片走本地内容寻址库；找不到时给出可见的占位提示，
/// 而不是静默空白（对应验收 D2/E1）。
///
/// 附件名字来自三处，优先级从高到低：
/// 1. 正文里的 alt 文本（新写入的引用形如 `![西湖.png](assets/<sha>.png)`）；
/// 2. [resolveName]（老数据只有 `![](assets/<sha>.png)`，用数据库里的原始文件名补上）；
/// 3. hash 短码兜底。
///
/// 名字渲染成彩色小标签，点一下就用系统默认程序打开附件。
class MarkdownView extends StatelessWidget {
  const MarkdownView({
    super.key,
    required this.data,
    required this.resolveLocalPath,
    this.resolveName,
    this.onOpenLink,
    this.padding = const EdgeInsets.fromLTRB(24, 16, 24, 64),
    this.emoji = const <String, String>{},
  });

  final String data;

  /// `assets/<sha>.<ext>` -> 本地绝对路径；返回 null 表示缺失。
  final String? Function(String reference) resolveLocalPath;

  /// `assets/<sha>.<ext>` -> 附件原始文件名；返回 null 表示查不到。
  final String? Function(String reference)? resolveName;
  final void Function(String reference)? onOpenLink;
  final EdgeInsets padding;

  /// 短代码 → 表情；为空时不做替换。
  final Map<String, String> emoji;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = applyEmoji(data, emoji);
    if (source.trim().isEmpty) {
      return Center(
        child: Text(
          '还没有内容',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final segments = splitMarkdownSegments(source);
    if (segments.length == 1 && segments.first.text != null) {
      return Padding(
        padding: padding,
        child: _markdownBody(context, segments.first.text!),
      );
    }
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final segment in segments)
            if (segment.text != null)
              _markdownBody(context, segment.text!)
            else if (segment.math != null)
              MathBlockView(tex: segment.math!)
            else if (segment.mermaid != null)
              MermaidCard(source: segment.mermaid!),
        ],
      ),
    );
  }

  Widget _markdownBody(BuildContext context, String markdown) {
    return MarkdownBody(
      data: markdown,
      selectable: true,
      styleSheet: _buildStyleSheet(context),
      inlineSyntaxes: <md.InlineSyntax>[MathInlineSyntax()],
      builders: <String, MarkdownElementBuilder>{
        'mathinline': MathInlineBuilder(),
      },
      imageBuilder: (uri, title, alt) {
        final reference = uri.toString();
        final path = resolveLocalPath(reference);
        final name = _attachmentName(reference, alt);
        final open = onOpenLink == null ? null : () => onOpenLink!(reference);
        if (path == null) {
          return _AttachmentChip(
            label: '附件缺失：$name',
            missing: true,
            onTap: open,
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              GestureDetector(
                onTap: open,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => _AttachmentChip(
                      label: '附件缺失：$name',
                      missing: true,
                      onTap: open,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              _AttachmentChip(label: name, missing: false, onTap: open),
            ],
          ),
        );
      },
      onTapLink: (text, href, title) {
        if (href != null && onOpenLink != null) onOpenLink!(href);
      },
    );
  }
  String _attachmentName(String reference, String? alt) {
    final fromAlt = (alt ?? '').trim();
    if (fromAlt.isNotEmpty && fromAlt != reference) return fromAlt;
    final fromStore = (resolveName?.call(reference) ?? '').trim();
    if (fromStore.isNotEmpty) return fromStore;
    var ref = reference.startsWith('assets/')
        ? reference.substring('assets/'.length)
        : reference;
    final dot = ref.lastIndexOf('.');
    if (dot > 0) ref = ref.substring(0, dot);
    return ref.length > 10 ? '${ref.substring(0, 8)}…' : ref;
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
      // 附件（`[文件名](assets/<sha>.ext)`）也走链接渲染：用强调色，和正文区分开。
      a: TextStyle(
        color: scheme.tertiary,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline,
        decorationColor: scheme.tertiary,
      ),
    );
  }
}

/// 附件名字标签：彩色 + 可点，点开用系统默认程序查看/编辑。
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.label,
    required this.missing,
    this.onTap,
  });

  final String label;
  final bool missing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = missing ? scheme.error : scheme.tertiary;
    final background = missing
        ? scheme.errorContainer
        : scheme.tertiaryContainer;
    return Material(
      color: background.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                missing ? Icons.link_off : Icons.attach_file,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!missing) ...<Widget>[
                const SizedBox(width: 4),
                Icon(Icons.open_in_new, size: 12, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
