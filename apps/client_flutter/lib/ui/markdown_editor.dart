import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 把一行 Markdown 上色：标题、粗体、行内代码、公式、链接。
List<TextSpan> highlightMarkdownLine(
  String line, {
  required TextStyle base,
  required Color heading,
  required Color code,
  required Color mathColor,
  required Color link,
}) {
  final headingMatch = RegExp(r'^(#{1,6})\s').firstMatch(line);
  if (headingMatch != null) {
    return <TextSpan>[
      TextSpan(
        text: line,
        style: base.copyWith(color: heading, fontWeight: FontWeight.w700),
      ),
    ];
  }
  final spans = <TextSpan>[];
  var last = 0;
  final pattern = RegExp(
    r'(\*\*[^*\n]+\*\*|`[^`\n]+`|\$[^$\n]+\$|\[[^\]\n]+\]\([^)\n]+\)|^>\s|^\s*[-*+]\s)',
  );
  for (final match in pattern.allMatches(line)) {
    if (match.start > last) {
      spans.add(TextSpan(text: line.substring(last, match.start), style: base));
    }
    final text = match.group(0)!;
    TextStyle style = base;
    if (text.startsWith('**')) {
      style = base.copyWith(fontWeight: FontWeight.w700);
    } else if (text.startsWith('`')) {
      style = base.copyWith(color: code, fontFamily: 'Cascadia Mono');
    } else if (text.startsWith(r'$')) {
      style = base.copyWith(color: mathColor);
    } else if (text.startsWith('[')) {
      style = base.copyWith(color: link, decoration: TextDecoration.underline);
    } else {
      style = base.copyWith(color: heading.withValues(alpha: 0.8));
    }
    spans.add(TextSpan(text: text, style: style));
    last = match.end;
  }
  if (last < line.length) {
    spans.add(TextSpan(text: line.substring(last), style: base));
  }
  return spans.isEmpty ? <TextSpan>[TextSpan(text: line, style: base)] : spans;
}

/// 带语法高亮的正文控制器。
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final scheme = Theme.of(context).colorScheme;
    final children = <TextSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      children.addAll(
        highlightMarkdownLine(
          lines[i],
          base: base,
          heading: scheme.primary,
          code: scheme.tertiary,
          mathColor: scheme.secondary,
          link: scheme.tertiary,
        ),
      );
      if (i != lines.length - 1) children.add(TextSpan(text: '\n', style: base));
    }
    return TextSpan(style: base, children: children);
  }
}

/// 自动配对：输入 `(`、`[`、`` ` ``、`"`、`'` 时补另一半。
class AutoPairFormatter extends TextInputFormatter {
  static const Map<String, String> pairs = <String, String>{
    '(': ')',
    '[': ']',
    '`': '`',
    '"': '"',
    "'": "'",
  };

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length == oldValue.text.length + 1) {
      final cursor = newValue.selection.baseOffset;
      if (cursor > 0) {
        final inserted = newValue.text[cursor - 1];
        final close = pairs[inserted];
        final selected = oldValue.selection;
        if (close != null) {
          final text = newValue.text;
          // 已有选区时包住选区
          if (selected.isValid && selected.start != selected.end) {
            final start = math.min(selected.start, selected.end);
            final end = math.max(selected.start, selected.end);
            final body = oldValue.text.substring(start, end);
            final replaced = '${oldValue.text.substring(0, start)}$inserted$body$close${oldValue.text.substring(end)}';
            return TextEditingValue(
              text: replaced,
              selection: TextSelection(
                baseOffset: start + 1,
                extentOffset: start + 1 + body.length,
              ),
            );
          }
          // 光标前一个字符是同一个符号：跳过而不是重复插入
          if (cursor < newValue.text.length &&
              newValue.text[cursor] == close) {
            return TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: cursor + 1),
            );
          }
          final withClose = text.substring(0, cursor) +
              close +
              text.substring(cursor);
          return TextEditingValue(
            text: withClose,
            selection: TextSelection.collapsed(offset: cursor),
          );
        }
      }
    }
    return newValue;
  }
}

/// 回车续列表：`- ` / `1. ` 自动续行；空列表项回车取消。
TextEditingValue? continueListOnEnter(TextEditingValue value) {
  final cursor = value.selection.baseOffset;
  if (cursor < 0 || cursor != value.selection.extentOffset) return null;
  final before = value.text.substring(0, cursor);
  final lineStart = before.lastIndexOf('\n') + 1;
  final line = before.substring(lineStart);
  final match = RegExp(r'^(\s*)([-*+]|\d+\.)\s(.*)$').firstMatch(line);
  if (match == null) return null;
  final indent = match.group(1)!;
  final marker = match.group(2)!;
  final rest = match.group(3)!;
  if (rest.trim().isEmpty) {
    // 空项：删掉这一行前缀
    final text = value.text.substring(0, lineStart) + value.text.substring(cursor);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: lineStart),
    );
  }
  final next = marker.endsWith('.')
      ? '${int.tryParse(marker.substring(0, marker.length - 1))! + 1}.'
      : marker;
  final insert = '\n$indent$next ';
  return TextEditingValue(
    text: value.text.substring(0, cursor) + insert + value.text.substring(cursor),
    selection: TextSelection.collapsed(offset: cursor + insert.length),
  );
}

/// Tab / Shift+Tab：缩进或反缩进当前行（有选区则整段）。
void indentSelection(TextEditingController controller, {required bool outdent}) {
  final value = controller.value;
  final selection = value.selection;
  final start = selection.isValid ? selection.start : value.text.length;
  final end = selection.isValid ? selection.end : start;
  final text = value.text;
  final lineStart = text.lastIndexOf('\n', start - 1) + 1;
  final block = text.substring(lineStart, end);
  final changed = outdent
      ? block.replaceAll(RegExp(r'^ {1,2}', multiLine: true), '')
      : block.replaceAll(RegExp(r'^', multiLine: true), '  ');
  final delta = changed.length - block.length;
  controller.value = TextEditingValue(
    text: text.replaceRange(lineStart, end, changed),
    selection: TextSelection(
      baseOffset: math.max(lineStart, start + (outdent ? math.min(0, delta) : 2)),
      extentOffset: math.max(lineStart, end + delta),
    ),
  );
}

/// 查找替换（支持整词/大小写/正则由 UI 控制，这里做纯逻辑）。
class FindReplaceController {
  FindReplaceController(this.controller);

  final TextEditingController controller;
  bool regex = false;
  bool caseSensitive = false;
  String query = '';
  String replacement = '';
  int _last = -1;

  RegExp? _pattern() {
    if (query.isEmpty) return null;
    final source = regex ? query : RegExp.escape(query);
    return RegExp(source, caseSensitive: caseSensitive);
  }

  bool findNext({bool backwards = false}) {
    final pattern = _pattern();
    if (pattern == null) return false;
    final text = controller.text;
    if (backwards) {
      final before = _last < 0 ? text.length : _last;
      final matches = pattern.allMatches(text.substring(0, before)).toList();
      if (matches.isEmpty) return false;
      final match = matches.last;
      _select(match.start, match.end);
      return true;
    }
    final from = _last < 0 ? (controller.selection.baseOffset.clamp(0, text.length)) : _last + 1;
    final match = _first(pattern.allMatches(text, from));
    if (match == null) {
      final wrapped = _first(pattern.allMatches(text));
      if (wrapped == null) return false;
      _select(wrapped.start, wrapped.end);
      return true;
    }
    _select(match.start, match.end);
    return true;
  }

  int replaceAll() {
    final pattern = _pattern();
    if (pattern == null) return 0;
    final text = controller.text;
    final matches = pattern.allMatches(text).toList();
    if (matches.isEmpty) return 0;
    controller.text = text.replaceAll(pattern, replacement);
    _last = -1;
    return matches.length;
  }

  bool replaceCurrent() {
    final pattern = _pattern();
    if (pattern == null) return false;
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return findNext();
    final selected = controller.text.substring(selection.start, selection.end);
    if (pattern.firstMatch(selected)?.group(0) != selected) return findNext();
    final text = controller.text;
    controller.value = TextEditingValue(
      text: text.replaceRange(selection.start, selection.end, replacement),
      selection: TextSelection.collapsed(offset: selection.start + replacement.length),
    );
    _last = selection.start + replacement.length;
    return true;
  }

  void _select(int start, int end) {
    controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    _last = start;
  }
}

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$', multiLine: true);

/// 收集标题（大纲）。
List<({int offset, int level, String title})> collectHeadings(String text) {
  final result = <({int offset, int level, String title})>[];
  for (final match in _headingPattern.allMatches(text)) {
    result.add((
      offset: match.start,
      level: match.group(1)!.length,
      title: match.group(2)!.trim(),
    ));
  }
  return result;
}
Match? _first(Iterable<Match> matches) => matches.isEmpty ? null : matches.first;
/// 在光标处插入（有选区则替换）。
void insertAtCursor(TextEditingController controller, String snippet) {
  final value = controller.value;
  final selection = value.selection;
  final start = selection.isValid ? selection.start : value.text.length;
  final end = selection.isValid ? selection.end : start;
  final text = value.text.replaceRange(start, end, snippet);
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + snippet.length),
  );
}

/// 查找替换对话框；[onChanged] 用于触发预览/自动保存。
Future<void> showFindReplaceDialog(
  BuildContext context,
  TextEditingController controller,
  VoidCallback onChanged,
) async {
  final find = FindReplaceController(controller);
  final query = TextEditingController();
  final replacement = TextEditingController();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('查找与替换'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: query,
                autofocus: true,
                onChanged: (value) => find.query = value,
                decoration: const InputDecoration(
                  labelText: '查找',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: replacement,
                onChanged: (value) => find.replacement = value,
                decoration: const InputDecoration(
                  labelText: '替换为',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Checkbox(
                    value: find.caseSensitive,
                    onChanged: (value) => setDialogState(
                      () => find.caseSensitive = value ?? false,
                    ),
                  ),
                  const Text('区分大小写'),
                  const SizedBox(width: 8),
                  Checkbox(
                    value: find.regex,
                    onChanged: (value) =>
                        setDialogState(() => find.regex = value ?? false),
                  ),
                  const Text('正则'),
                ],
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => find.findNext(backwards: true),
            child: const Text('上一个'),
          ),
          TextButton(
            onPressed: () => find.findNext(),
            child: const Text('下一个'),
          ),
          TextButton(
            onPressed: () => find.replaceCurrent(),
            child: const Text('替换'),
          ),
          TextButton(
            onPressed: () {
              final count = find.replaceAll();
              onChanged();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('替换了 $count 处')),
              );
            },
            child: const Text('全部替换'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
  query.dispose();
  replacement.dispose();
}

/// 大纲对话框。
Future<void> showOutlineDialog(
  BuildContext context,
  TextEditingController controller,
  FocusNode focus,
) async {
  final headings = collectHeadings(controller.text);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('大纲'),
      children: <Widget>[
        if (headings.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('还没有标题（用 # 开头）'),
          )
        else
          for (final heading in headings)
            SimpleDialogOption(
              onPressed: () {
                controller.selection = TextSelection.collapsed(
                  offset: heading.offset,
                );
                focus.requestFocus();
                Navigator.of(dialogContext).pop();
              },
              child: Padding(
                padding: EdgeInsets.only(left: (heading.level - 1) * 16.0),
                child: Text(
                  heading.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
      ],
    ),
  );
}

/// 命令面板：插入常用结构 + 打开查找/大纲。
Future<void> showCommandPalette(
  BuildContext context,
  TextEditingController controller, {
  required VoidCallback onChanged,
}) async {
  final commands = <(String, VoidCallback)>[
    ('插入表格', () => insertAtCursor(controller, '\n| 列1 | 列2 |\n| --- | --- |\n|  |  |\n')),
    ('插入行内公式', () => insertAtCursor(controller, r'$x^2$')),
    ('插入块级公式', () => insertAtCursor(controller, '\n\$\$\nE=mc^2\n\$\$\n')),
    ('插入 Mermaid', () => insertAtCursor(controller, '\n```mermaid\ngraph TD\nA --> B\n```\n')),
    ('查找替换', () => showFindReplaceDialog(context, controller, onChanged)),
  ];
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('命令面板'),
      children: <Widget>[
        for (final command in commands)
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              command.$2();
            },
            child: Text(command.$1),
          ),
      ],
    ),
  );
}