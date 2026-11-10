import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../ui/emoji_picker.dart';
import '../ui/markdown_editor.dart';
import '../ui/markdown_view.dart';
import '../ui/symbol_palette.dart';
import '../state/app_scope.dart';

/// 子 md 文件编辑器：与主文件相同的语法高亮 / 工具栏 / 预览分栏。
class ChildNotePage extends StatefulWidget {
  const ChildNotePage({
    super.key,
    required this.initialName,
    required this.initialText,
  });

  final String initialName;
  final String initialText;

  @override
  State<ChildNotePage> createState() => _ChildNotePageState();
}

class _ChildNotePageState extends State<ChildNotePage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final MarkdownEditingController _body = MarkdownEditingController(
    text: widget.initialText,
  );
  bool _preview = false;
  final FocusNode _outlineFocus = FocusNode();

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    _outlineFocus.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim().isEmpty ? '子笔记.md' : _name.text.trim();
    Navigator.of(context).pop(<String, String>{
      'name': name.endsWith('.md') ? name : '$name.md',
      'text': _body.text,
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final style = AppTheme.editorStyle(
      state.editorFontSize,
      theme.colorScheme.onSurface,
      fontFamily: state.editorFont,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_preview ? '预览 · ${_name.text}' : '编辑子 md'),
        centerTitle: false,
        actions: <Widget>[
          IconButton(
            tooltip: _preview ? '编辑' : '预览',
            onPressed: () => setState(() => _preview = !_preview),
            icon: Icon(
              _preview ? Icons.edit_outlined : Icons.visibility_outlined,
            ),
          ),
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!_preview)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: TextField(
                controller: _name,
                style: theme.textTheme.titleMedium,
                decoration: const InputDecoration(
                  labelText: '文件名',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          Expanded(
            child: _preview
                ? SingleChildScrollView(
                    child: MarkdownView(
                      data: _body.text,
                      resolveLocalPath: (_) => null,
                      emoji: state.emojiMap,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _body,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: style,
                            inputFormatters: <TextInputFormatter>[
                              AutoPairFormatter(),
                            ],
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              hintText: '写子笔记…保存后作为附件链接到主文件',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          if (!_preview)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '符号与公式',
                    onPressed: () => showSymbolPalette(context, _body),
                    icon: const Icon(Icons.functions),
                  ),
                  IconButton(
                    tooltip: '表情',
                    onPressed: () async {
                      final code = await showEmojiPicker(context, state: state);
                      if (code == null || !mounted) return;
                      insertSymbol(_body, SymbolItem(code, ':$code: '));
                    },
                    icon: const Icon(Icons.emoji_emotions_outlined),
                  ),
                  IconButton(
                    tooltip: '查找替换',
                    onPressed: () =>
                        showFindReplaceDialog(context, _body, () {}),
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    tooltip: '大纲',
                    onPressed: () =>
                        showOutlineDialog(context, _body, _outlineFocus),
                    icon: const Icon(Icons.list_alt),
                  ),
                  const Spacer(),
                  Text(
                    '${state.editorFontSize.round()} px',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
