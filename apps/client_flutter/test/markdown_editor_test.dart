import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/ui/markdown_editor.dart';

/// v2.8：Markdown 编辑辅助（高亮/配对/续行/查找/大纲）。
void main() {
  test('标题行整行高亮加粗', () {
    final spans = highlightMarkdownLine(
      '## 今天',
      base: const TextStyle(),
      heading: const Color(0xFF0000FF),
      code: const Color(0xFF00AA00),
      mathColor: const Color(0xFFAA00AA),
      link: const Color(0xFF0000AA),
    );
    expect(spans.single.style?.fontWeight, FontWeight.w700);
    expect(spans.single.style?.color, const Color(0xFF0000FF));
  });

  test('行内代码与公式有独立样式', () {
    final spans = highlightMarkdownLine(
      '前 `code` 和 \$x^2\$',
      base: const TextStyle(),
      heading: const Color(0xFF0000FF),
      code: const Color(0xFF00AA00),
      mathColor: const Color(0xFFAA00AA),
      link: const Color(0xFF0000AA),
    );
    expect(spans.any((s) => s.style?.color == const Color(0xFF00AA00)), isTrue);
    expect(spans.any((s) => s.style?.color == const Color(0xFFAA00AA)), isTrue);
  });

  test('自动配对括号并选中中间', () {
    final formatter = AutoPairFormatter();
    final value = formatter.formatEditUpdate(
      const TextEditingValue(text: ''),
      const TextEditingValue(
        text: '(',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    expect(value.text, '()');
    expect(value.selection.baseOffset, 1);
  });

  test('回车续列表，空项取消', () {
    const value = TextEditingValue(
      text: '- 第一项',
      selection: TextSelection.collapsed(offset: 5),
    );
    final next = continueListOnEnter(value);
    expect(next?.text, '- 第一项\n- ');

    const empty = TextEditingValue(
      text: '- ',
      selection: TextSelection.collapsed(offset: 2),
    );
    expect(continueListOnEnter(empty)?.text, '');
  });

  test('有序列表编号递增', () {
    const value = TextEditingValue(
      text: '1. a',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(continueListOnEnter(value)?.text, '1. a\n2. ');
  });

  test('查找替换：全部替换与大小写', () {
    final controller = TextEditingController(text: 'Cat cat CAT');
    final find = FindReplaceController(controller)
      ..query = 'cat'
      ..replacement = 'dog';
    expect(find.replaceAll(), 3);
    expect(controller.text, 'dog dog dog');

    controller.text = 'Cat cat';
    final sensitive = FindReplaceController(controller)
      ..query = 'cat'
      ..replacement = 'dog'
      ..caseSensitive = true;
    expect(sensitive.replaceAll(), 1);
    expect(controller.text, 'Cat dog');
  });

  test('大纲收集标题层级与偏移', () {
    final headings = collectHeadings('# 一\n\n## 二\n正文\n### 三');
    expect(headings.map((h) => h.title), <String>['一', '二', '三']);
    expect(headings.map((h) => h.level), <int>[1, 2, 3]);
  });
}
