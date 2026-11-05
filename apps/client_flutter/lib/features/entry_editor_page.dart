import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../ui/markdown_view.dart';

enum EditorMode { edit, split, preview }

/// 右侧编辑区：标题 + 正文 + 工具栏 + 附件条。
///
/// 本组件不直接写数据库：内容变化交给 AppState 做 800ms 防抖落库。
class EntryEditorPage extends StatefulWidget {
  const EntryEditorPage({super.key, required this.state, required this.entry});

  final AppState state;
  final Entry entry;

  @override
  State<EntryEditorPage> createState() => _EntryEditorPageState();
}

class _EntryEditorPageState extends State<EntryEditorPage> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.entry.title,
  );
  late final TextEditingController _bodyController = TextEditingController(
    text: widget.entry.bodyMd,
  );
  final FocusNode _bodyFocus = FocusNode();

  EditorMode _mode = EditorMode.edit;
  List<Attachment> _attachments = const <Attachment>[];
  bool _busy = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _reloadAttachments();
  }

  @override
  void didUpdateWidget(covariant EntryEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) {
      _titleController.text = widget.entry.title;
      _bodyController.text = widget.entry.bodyMd;
      _reloadAttachments();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _reloadAttachments() {
    _attachments = _state.attachmentsOf(widget.entry.id);
  }

  void _onTitleChanged(String value) {
    _state.draftChanged(title: value);
    _reloadAttachments();
  }

  void _onBodyChanged(String value) {
    _state.draftChanged(body: value);
    setState(() {});
  }

  Future<void> _insertAttachment() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final attached = await _state.pickAttachment(widget.entry);
      if (attached == null || !mounted) return;
      _insertMarkdown(attached.markdownLink);
      setState(_reloadAttachments);
    } on Object catch (error) {
      if (mounted) _showMessage('添加附件失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 粘贴截图（Windows）：剪贴板里是图片就落成附件并插入引用。
  Future<void> _pasteScreenshot() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final attached = await _state.pasteClipboardImage(widget.entry);
      if (!mounted) return;
      if (attached == null) {
        _showMessage('剪贴板里没有图片（先截图或复制一张图）');
        return;
      }
      _insertMarkdown(attached.markdownLink);
      setState(_reloadAttachments);
    } on Object catch (error) {
      if (mounted) _showMessage('粘贴截图失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 把 Markdown 片段插到光标处（附件、截图共用）。
  void _insertMarkdown(String markdown) {
    final link = '$markdown\n';
    final selection = _bodyController.selection;
    final text = _bodyController.text;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final next = text.replaceRange(start, end, link);
    _bodyController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + link.length),
    );
    _state.draftChanged(body: next);
    _bodyFocus.requestFocus();
  }

  Future<void> _export() async {
    try {
      final path = await _state.exportCurrent(widget.entry);
      if (path != null && mounted) _showMessage('已导出到 $path');
    } catch (error) {
      if (mounted) _showMessage('导出失败：$error');
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这篇日记？'),
        content: const Text('会移入回收站，可随时恢复；在回收站彻底删除才会移除附件。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移到回收站'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _state.deleteEntry(widget.entry);
      if (mounted) _showMessage('已移入回收站');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  String? _resolveReference(String reference) {
    var ref = reference;
    if (ref.startsWith('./')) ref = ref.substring(2);
    if (ref.startsWith('assets/')) ref = ref.substring('assets/'.length);
    final dot = ref.lastIndexOf('.');
    final hash = dot > 0 ? ref.substring(0, dot) : ref;
    final ext = dot > 0 ? ref.substring(dot) : '';
    if (hash.length != 64) return null;
    return _state.store.pathFor(hash, ext);
  }

  /// 老数据正文里只有 `![](assets/<sha>.png)`，没有文件名；
  /// 用当前日记的附件表反查原始文件名，预览里就能显示「西湖.png」。
  String? _nameOfReference(String reference) {
    var ref = reference;
    if (ref.startsWith('./')) ref = ref.substring(2);
    if (ref.startsWith('assets/')) ref = ref.substring('assets/'.length);
    final dot = ref.lastIndexOf('.');
    final hash = dot > 0 ? ref.substring(0, dot) : ref;
    for (final attachment in _attachments) {
      if (attachment.sha256 == hash) return attachment.filename;
    }
    return null;
  }

  void _onOpenReference(String reference) {
    final local = _resolveReference(reference);
    if (local != null) {
      _state.openInSystem(local);
      return;
    }
    if (reference.startsWith('http')) {
      _state.openInSystem(reference);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: <Widget>[
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
        if (_attachments.isNotEmpty) ...<Widget>[
          const Divider(height: 1),
          _buildAttachmentStrip(context),
        ],
        const Divider(height: 1),
        _buildFooter(context, scheme),
      ],
    );
  }

  Future<void> _editTags() async {
    final state = _state;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) =>
          _TagEditDialog(initial: state.tagsOf(widget.entry.id)),
    );
    if (result == null || !mounted) return;
    await state.setTags(widget.entry, result);
    if (mounted) setState(() {});
  }

  Widget _buildTagStrip(BuildContext context) {
    final theme = Theme.of(context);
    final tags = _state.tagsOf(widget.entry.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final tag in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '#$tag',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          TextButton.icon(
            onPressed: _editTags,
            icon: const Icon(Icons.sell_outlined, size: 16),
            label: Text(tags.isEmpty ? '添加标签' : '编辑标签'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const Key('editor-title'),
            controller: _titleController,
            onChanged: _onTitleChanged,
            textInputAction: TextInputAction.next,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '标题（可留空，导出时取正文首行）',
            ),
          ),
          const SizedBox(height: 6),
          // 用 Wrap 而不是 Row：窗口收窄时模式切换与操作按钮自动换行，不会溢出
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                SegmentedButton<EditorMode>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const <ButtonSegment<EditorMode>>[
                    ButtonSegment<EditorMode>(
                      value: EditorMode.edit,
                      icon: Icon(Icons.edit_note, size: 18),
                      label: Text('编辑'),
                    ),
                    ButtonSegment<EditorMode>(
                      value: EditorMode.split,
                      icon: Icon(Icons.vertical_split_outlined, size: 18),
                      label: Text('分栏'),
                    ),
                    ButtonSegment<EditorMode>(
                      value: EditorMode.preview,
                      icon: Icon(Icons.visibility_outlined, size: 18),
                      label: Text('预览'),
                    ),
                  ],
                  selected: <EditorMode>{_mode},
                  onSelectionChanged: (selection) =>
                      setState(() => _mode = selection.first),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: '插入附件（≤ 100 MB）',
                      onPressed: _busy ? null : _insertAttachment,
                      icon: const Icon(Icons.attach_file),
                    ),
                    IconButton(
                      tooltip: '粘贴截图（Ctrl+Shift+V）',
                      onPressed: _busy ? null : _pasteScreenshot,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                    ),
                    IconButton(
                      tooltip: '导出为 .md',
                      onPressed: _export,
                      icon: const Icon(Icons.file_download_outlined),
                    ),
                    IconButton(
                      tooltip: widget.entry.pinned ? '取消置顶' : '置顶',
                      onPressed: () => _state.togglePin(widget.entry),
                      icon: Icon(
                        widget.entry.pinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                      ),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _buildTagStrip(context),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_mode) {
      case EditorMode.edit:
        return _buildEditor(context);
      case EditorMode.preview:
        return SingleChildScrollView(
          child: MarkdownView(
            data: _bodyController.text,
            resolveLocalPath: _resolveReference,
            resolveName: _nameOfReference,
            onOpenLink: _onOpenReference,
          ),
        );
      case EditorMode.split:
        return Row(
          children: <Widget>[
            Expanded(child: _buildEditor(context)),
            const VerticalDivider(width: 1),
            Expanded(
              child: SingleChildScrollView(
                child: MarkdownView(
                  data: _bodyController.text,
                  resolveLocalPath: _resolveReference,
                  resolveName: _nameOfReference,
                  onOpenLink: _onOpenReference,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
                ),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildEditor(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      // Ctrl+Shift+V 粘贴截图：用 Ctrl+Shift 组合，不抢 TextField 自带的 Ctrl+V 文本粘贴。
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              HardwareKeyboard.instance.isControlPressed &&
              HardwareKeyboard.instance.isShiftPressed &&
              event.logicalKey == LogicalKeyboardKey.keyV) {
            _pasteScreenshot();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          key: const Key('editor-body'),
          controller: _bodyController,
          focusNode: _bodyFocus,
          onChanged: _onBodyChanged,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: AppTheme.editorStyle(
            _state.editorFontSize,
            theme.colorScheme.onSurface,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: '写点什么…支持 Markdown，输入后自动保存',
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentStrip(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _attachments.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = _attachments[index];
          final local = _state.localPathOf(attachment);
          final missing = local == null;
          return InputChip(
            avatar: Icon(
              missing ? Icons.link_off : Icons.attachment,
              size: 16,
              color: missing
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
            label: Text(
              '${attachment.filename}  ${formatBytes(attachment.sizeBytes)}',
              style: theme.textTheme.labelSmall,
            ),
            onPressed: _openAttachmentCallback(local),
            tooltip: missing ? '附件文件缺失' : '用系统默认程序打开',
          );
        },
      ),
    );
  }

  VoidCallback? _openAttachmentCallback(String? path) {
    if (path == null) return null;
    return () => _state.openInSystem(path);
  }

  Widget _buildFooter(BuildContext context, ColorScheme scheme) {
    final theme = Theme.of(context);
    final chars = countCharacters(_bodyController.text);
    final updated = widget.entry.updatedAt;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        // 窄窗口下两段文字改为换行排列，避免 Row 溢出
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 2,
          children: <Widget>[
            Text(
              '${formatDayLabel(widget.entry.entryDate)} · $chars 字',
              style: style,
            ),
            Text('最后保存 ${formatDateTime(updated)}', style: style),
          ],
        ),
      ),
    );
  }
}

/// 标签编辑对话框：自己管理 TextEditingController，
/// 避免「对话框还在退场动画里，controller 已经被外部 dispose」。
class _TagEditDialog extends StatefulWidget {
  const _TagEditDialog({required this.initial});

  final List<String> initial;

  @override
  State<_TagEditDialog> createState() => _TagEditDialogState();
}

class _TagEditDialogState extends State<_TagEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial.join(' '),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 逗号/空格/顿号分隔，允许用户顺手敲 `#标签`。
  static List<String> parse(String raw) => raw
      .split(RegExp(r'[,，、\s]+'))
      .map((tag) => tag.trim().replaceAll(RegExp(r'^#+'), '').trim())
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑标签'),
      content: TextField(
        key: const Key('tag-input'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '空格或逗号分隔，例如：旅行 杭州',
          helperText: '标签会写进导出 .md 的 front matter，也能在搜索框里搜到',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(parse(value)),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(parse(_controller.text)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
