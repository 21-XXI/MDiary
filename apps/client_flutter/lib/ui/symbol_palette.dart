import 'package:flutter/material.dart';

/// 一个可插入的符号 / 语法片段。
class SymbolItem {
  const SymbolItem(
    this.label,
    this.prefix, {
    this.suffix = '',
    this.placeholder = '',
    this.hint = '',
  });

  final String label;
  final String prefix;
  final String suffix;
  final String placeholder;
  final String hint;
}

/// 在光标处插入片段；有选区时用选区替换占位符。
void insertSymbol(TextEditingController controller, SymbolItem item) {
  final text = controller.text;
  final selection = controller.selection;
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : start;
  final selected = start <= end ? text.substring(start, end) : '';
  final middle = selected.isEmpty ? item.placeholder : selected;
  final inserted = '${item.prefix}$middle${item.suffix}';
  final value = text.replaceRange(start, end, inserted);
  final caretStart = start + item.prefix.length;
  controller.value = TextEditingValue(
    text: value,
    selection: TextSelection(
      baseOffset: caretStart,
      extentOffset: caretStart + middle.length,
    ),
  );
}

const List<SymbolItem> markdownSymbols = <SymbolItem>[
  SymbolItem('H2', '\n## ', hint: '二级标题'),
  SymbolItem('H3', '\n### ', hint: '三级标题'),
  SymbolItem('粗体', '**', suffix: '**', placeholder: '粗体', hint: '加粗'),
  SymbolItem('斜体', '*', suffix: '*', placeholder: '斜体', hint: '斜体'),
  SymbolItem('删除线', '~~', suffix: '~~', placeholder: '删除', hint: '删除线'),
  SymbolItem('引用', '\n> ', hint: '引用块'),
  SymbolItem('列表', '\n- ', hint: '无序列表'),
  SymbolItem('有序', '\n1. ', hint: '有序列表'),
  SymbolItem('任务', '\n- [ ] ', hint: '待办项'),
  SymbolItem('行内码', '`', suffix: '`', placeholder: 'code'),
  SymbolItem('代码块', '\n```\n', suffix: '\n```\n', placeholder: 'code'),
  SymbolItem('链接', '[', suffix: '](url)', placeholder: '文字'),
  SymbolItem('图片', '![', suffix: '](path)', placeholder: '说明'),
  SymbolItem('表格', '\n| 列1 | 列2 |\n| --- | --- |\n|  |  |\n', hint: '插入表格'),
  SymbolItem('分隔线', '\n---\n'),
];

const List<SymbolItem> mathSymbols = <SymbolItem>[
  SymbolItem('行内公式', r'$', suffix: r'$', placeholder: 'x^2', hint: r'$...$'),
  SymbolItem('块级公式', '\n\$\$\n', suffix: '\n\$\$\n', placeholder: r'E = mc^2', hint: r'$$...$$'),
  SymbolItem('分数', r'\frac{', suffix: '}{}', placeholder: 'a', hint: r'\frac{a}{b}'),
  SymbolItem('上标', '^{', suffix: '}', placeholder: '2'),
  SymbolItem('下标', '_{', suffix: '}', placeholder: 'i'),
  SymbolItem('根号', r'\sqrt{', suffix: '}', placeholder: 'x'),
  SymbolItem('求和', r'\sum_{i=1}^{n} ', placeholder: ''),
  SymbolItem('积分', r'\int_{a}^{b} ', placeholder: ''),
  SymbolItem('极限', r'\lim_{x \to \infty} ', placeholder: ''),
  SymbolItem('乘号', r'\times '),
  SymbolItem('除号', r'\div '),
  SymbolItem('小于等于', r'\le '),
  SymbolItem('大于等于', r'\ge '),
  SymbolItem('不等于', r'\ne '),
  SymbolItem('约等于', r'\approx '),
  SymbolItem('无穷', r'\infty '),
];

const List<SymbolItem> greekSymbols = <SymbolItem>[
  SymbolItem('α', 'α'),
  SymbolItem('β', 'β'),
  SymbolItem('γ', 'γ'),
  SymbolItem('δ', 'δ'),
  SymbolItem('ε', 'ε'),
  SymbolItem('θ', 'θ'),
  SymbolItem('λ', 'λ'),
  SymbolItem('μ', 'μ'),
  SymbolItem('π', 'π'),
  SymbolItem('σ', 'σ'),
  SymbolItem('φ', 'φ'),
  SymbolItem('ω', 'ω'),
  SymbolItem('Δ', 'Δ'),
  SymbolItem('Σ', 'Σ'),
  SymbolItem('Ω', 'Ω'),
];

const List<SymbolItem> arrowSymbols = <SymbolItem>[
  SymbolItem('→', '→'),
  SymbolItem('←', '←'),
  SymbolItem('↑', '↑'),
  SymbolItem('↓', '↓'),
  SymbolItem('⇒', '⇒'),
  SymbolItem('⇐', '⇐'),
  SymbolItem('↔', '↔'),
  SymbolItem('⇔', '⇔'),
];

const List<SymbolItem> logicSymbols = <SymbolItem>[
  SymbolItem('∈', '∈'),
  SymbolItem('∉', '∉'),
  SymbolItem('⊂', '⊂'),
  SymbolItem('⊆', '⊆'),
  SymbolItem('∪', '∪'),
  SymbolItem('∩', '∩'),
  SymbolItem('∀', '∀'),
  SymbolItem('∃', '∃'),
  SymbolItem('∅', '∅'),
  SymbolItem('≤', '≤'),
  SymbolItem('≥', '≥'),
  SymbolItem('≠', '≠'),
  SymbolItem('≈', '≈'),
  SymbolItem('±', '±'),
  SymbolItem('×', '×'),
  SymbolItem('÷', '÷'),
  SymbolItem('∞', '∞'),
];

const List<SymbolItem> miscSymbols = <SymbolItem>[
  SymbolItem('°', '°'),
  SymbolItem('℃', '℃'),
  SymbolItem('‰', '‰'),
  SymbolItem('§', '§'),
  SymbolItem('¶', '¶'),
  SymbolItem('•', '•'),
  SymbolItem('…', '…'),
  SymbolItem('—', '—'),
  SymbolItem('–', '–'),
  SymbolItem('€', '€'),
  SymbolItem('¥', '¥'),
  SymbolItem('✓', '✓'),
];

/// 打开常用符号提示表。点一个就插到光标处，对话框保持打开以便连续插入。
Future<void> showSymbolPalette(
  BuildContext context,
  TextEditingController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: const Text('符号与公式'),
        content: SizedBox(
          width: 760,
          height: 520,
          child: ListView(
            children: <Widget>[
              Text(
                '点一下插入到光标处；选中的文字会被包裹。数学公式用 \$...\$ 或 \$\$...\$\$。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final group in <_Group>[
                _Group('Markdown 结构', markdownSymbols),
                _Group('数学公式（TeX）', mathSymbols),
                _Group('希腊字母', greekSymbols),
                _Group('箭头', arrowSymbols),
                _Group('逻辑与集合', logicSymbols),
                _Group('常用符号', miscSymbols),
              ])
                _SymbolGroup(group: group, controller: controller),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

class _Group {
  const _Group(this.title, this.items);

  final String title;
  final List<SymbolItem> items;
}

class _SymbolGroup extends StatelessWidget {
  const _SymbolGroup({required this.group, required this.controller});

  final _Group group;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(group.title, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final item in group.items)
                Tooltip(
                  message: item.hint.isEmpty ? item.label : item.hint,
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(item.label),
                    onPressed: () => insertSymbol(controller, item),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
