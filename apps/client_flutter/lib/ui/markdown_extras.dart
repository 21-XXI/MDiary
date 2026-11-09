import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// 预览里的一个片段：普通 Markdown、块级公式或 Mermaid 图。
class MarkdownSegment {
  const MarkdownSegment.text(this.text) : math = null, mermaid = null;
  const MarkdownSegment.math(this.math) : text = null, mermaid = null;
  const MarkdownSegment.mermaid(this.mermaid) : text = null, math = null;

  final String? text;
  final String? math;
  final String? mermaid;
}

/// 把正文切成普通 Markdown / `$$...$$` / ```mermaid 三类片段。
///
/// 块级结构在渲染前先拆出来，比自定义 BlockSyntax 更稳（不影响 GFM 的其余语法）。
List<MarkdownSegment> splitMarkdownSegments(String data) {
  final lines = data.split('\n');
  final segments = <MarkdownSegment>[];
  final buffer = StringBuffer();

  void flushText() {
    final text = buffer.toString();
    if (text.trim().isNotEmpty) segments.add(MarkdownSegment.text(text));
    buffer.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed == '```mermaid') {
      flushText();
      final code = <String>[];
      i++;
      while (i < lines.length && lines[i].trim() != '```') {
        code.add(lines[i]);
        i++;
      }
      segments.add(MarkdownSegment.mermaid(code.join('\n')));
      continue;
    }

    if (trimmed == r'$$') {
      flushText();
      final tex = <String>[];
      i++;
      while (i < lines.length && lines[i].trim() != r'$$') {
        tex.add(lines[i]);
        i++;
      }
      segments.add(MarkdownSegment.math(tex.join('\n')));
      continue;
    }

    // 行内出现的 `$$...$$`（前后还有文字）也按块级公式处理。
    final singleLine = RegExp(r'\$\$([^\n]+?)\$\$').firstMatch(line);
    if (singleLine != null) {
      final before = line.substring(0, singleLine.start);
      if (before.trim().isNotEmpty) buffer.writeln(before);
      flushText();
      segments.add(MarkdownSegment.math(singleLine.group(1)!));
      final after = line.substring(singleLine.end);
      if (after.trim().isNotEmpty) buffer.writeln(after);
      continue;
    }

    buffer.writeln(line);
  }
  flushText();
  return segments;
}

/// 行内公式：`$E=mc^2$`（不匹配 `$$`）。
class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax() : super(r'\$(?!\$)([^\n$]+?)\$(?!\$)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = (match[1] ?? '').trim();
    if (tex.isEmpty) return false;
    parser.addNode(md.Element.text('mathinline', tex));
    return true;
  }
}

/// 行内公式渲染成 [Math] 组件（由 flutter_markdown_plus 放进段落里）。
class MathInlineBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.textContent.trim();
    if (tex.isEmpty) return null;
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: parentStyle ?? preferredStyle ?? const TextStyle(),
      onErrorFallback: (error) => _MathError(tex: tex, message: error.message),
    );
  }
}

/// 块级公式（居中、可横向滚动）。
class MathBlockView extends StatelessWidget {
  const MathBlockView({super.key, required this.tex});

  final String tex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Math.tex(
          tex,
          mathStyle: MathStyle.display,
          textStyle: theme.textTheme.bodyLarge ?? const TextStyle(),
          onErrorFallback: (error) => _MathError(tex: tex, message: error.message),
        ),
      ),
    );
  }
}

class _MathError extends StatelessWidget {
  const _MathError({required this.tex, required this.message});

  final String tex;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '公式解析失败：$message',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(tex, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Mermaid 图（当前版本渲染源码卡片；真实渲染需要 WebView2，见 docs/markdown.md）。
class MermaidCard extends StatelessWidget {
  const MermaidCard({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeStyle = TextStyle(
      fontFamily: 'Cascadia Mono',
      fontFamilyFallback: const <String>['Consolas', 'Microsoft YaHei'],
      fontSize: 12.5,
      height: 1.5,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.account_tree_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text('Mermaid 图', style: theme.textTheme.labelLarge),
                const Spacer(),
                Text(
                  '源码',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '复制源码',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: source));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制 Mermaid 源码，可粘贴到 mermaid.live')),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(source, style: codeStyle),
            ),
            const SizedBox(height: 6),
            Text(
              '当前版本展示源码；粘贴到 mermaid.live 可看渲染效果。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
