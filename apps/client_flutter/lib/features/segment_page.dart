import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../rag/diary_segmenter.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/widgets.dart';

/// 分词导入（v2.7 第二步）：文件夹 → 模型切分 → 预览 → 新建库并导入。
class SegmentPage extends StatefulWidget {
  const SegmentPage({super.key});

  @override
  State<SegmentPage> createState() => _SegmentPageState();
}

class _SegmentPageState extends State<SegmentPage> {
  final TextEditingController _name = TextEditingController();
  String? _folder;
  SegmentPlan? _plan;
  bool _busy = false;
  String _status = '';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick(AppState state) async {
    final dir = await state.pickDirectory(title: '选择要分词的文件夹');
    if (dir == null || !mounted) return;
    setState(() {
      _folder = dir;
      _plan = null;
      _error = null;
      _status = '';
      _name.text = p.basename(dir);
    });
  }

  Future<void> _analyze(AppState state) async {
    final folder = _folder;
    if (folder == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在读取资料并调用分词模型…';
    });
    try {
      final plan = await state.planSegmentation(folder);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _status = '切分完成：${plan.days.length} 天';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(AppState state) async {
    final plan = _plan;
    final folder = _folder;
    if (plan == null || folder == null || _busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在新建库并导入…';
    });
    try {
      final result = await state.importSegmentPlan(
        plan,
        sourceDirectory: folder,
        libraryName: name,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入完成'),
          content: Text(
            '已新建库「$name」并切换过去。\n'
            '导入 ${result.imported} 篇'
            '${result.skipped > 0 ? '，跳过 ${result.skipped} 篇' : ''}'
            '${result.errors.isEmpty ? '' : '，${result.errors.length} 条警告'}。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: const Text('分词导入'), centerTitle: false),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _folder ?? '先选一个包含 .md / .txt 的文件夹',
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _pick(state),
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('选择文件夹'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        SizedBox(
                          width: 96,
                          child: Text('新库名称', style: theme.textTheme.labelMedium),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _name,
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '默认用文件夹名',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _folder == null || _busy
                              ? null
                              : () => _analyze(state),
                          icon: const Icon(Icons.auto_fix_high, size: 18),
                          label: const Text('开始分词'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: plan == null || _busy
                              ? null
                              : () => _import(state),
                          icon: const Icon(Icons.library_add_outlined, size: 18),
                          label: const Text('确认导入'),
                        ),
                      ],
                    ),
                    if (_status.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        _status,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (_busy) ...<Widget>[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(minHeight: 3),
                    ],
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: plan == null
                ? const EmptyState(
                    icon: Icons.call_split,
                    title: '还没有分词结果',
                    description: '选文件夹 → 开始分词 → 检查预览 → 确认导入（会新建一个库）',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    children: <Widget>[
                      Text(
                        '${plan.days.length} 天 · ${plan.days.fold<int>(0, (sum, day) => sum + day.chars)} 字'
                        ' · ${plan.attachments} 个附件'
                        '${plan.warnings.isEmpty ? '' : ' · ${plan.warnings.length} 条警告'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final warning in plan.warnings.take(8))
                        Text(
                          '· $warning',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.tertiary,
                          ),
                        ),
                      const Divider(height: 18),
                      for (final day in plan.days)
                        ListTile(
                          dense: true,
                          leading: Text(
                            '${day.date.month}-${day.date.day}',
                            style: theme.textTheme.labelLarge,
                          ),
                          title: Text(day.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${day.chars} 字'
                            '${day.tags.isEmpty ? '' : ' · ${day.tags.join(' / ')}'}'
                            '${day.attachments.isEmpty ? '' : ' · 附件 ${day.attachments.length}'}',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
