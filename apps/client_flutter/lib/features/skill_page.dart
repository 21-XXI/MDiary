import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rag/skill_job.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/markdown_view.dart';
import '../ui/widgets.dart';

/// 蒸馏（v2.2）：把 soul.md + RAG 语料交给云端大模型，产出一份可复用的 skill。
///
/// 每次生成为一个新目录 `db/skill/<时间>/`，**从不覆盖**旧 skill。
class SkillPage extends StatefulWidget {
  const SkillPage({super.key});

  @override
  State<SkillPage> createState() => _SkillPageState();
}

class _SkillPageState extends State<SkillPage> {
  List<SkillEntry> _skills = const <SkillEntry>[];
  bool _busy = false;
  DistilledSkill? _last;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _load() {
    final state = AppScope.of(context);
    setState(() => _skills = state.listSkills());
  }

  Future<void> _distill(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final markdown = await state.previewSkill();
      if (!mounted) return;
      setState(() => _busy = false);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('预览 skill'),
          content: SizedBox(
            width: 760,
            height: 520,
            child: SingleChildScrollView(
              child: MarkdownView(
                data: markdown,
                resolveLocalPath: (_) => null,
                emoji: state.emojiMap,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('保存为新 skill'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);
      final skill = await state.saveSkill(markdown);
      if (!mounted) return;
      setState(() {
        _last = skill;
        _skills = state.listSkills();
      });
      _snack('已生成 ${skill.directory.split(RegExp(r'[\\/]')).last}（${skill.bytes} 字节）');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('蒸馏'), centerTitle: false),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    value: state.skillEnabled,
                    onChanged: state.setSkillEnabled,
                    title: const Text('启用蒸馏'),
                    subtitle: const Text(
                      '把 soul.md 和索引语料交给云端大模型，压成一份可复用的 skill；'
                      '每次生成新目录，不覆盖旧的',
                    ),
                  ),
                  if (state.skillEnabled) ...<Widget>[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                state.canDistill
                                    ? Icons.cloud_done_outlined
                                    : Icons.cloud_off_outlined,
                                size: 16,
                                color: state.canDistill
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.error,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  state.cloudEnabled
                                      ? '云端模型：${state.ragSettings.cloudModel}（${state.ragSettings.cloudBaseUrl}）'
                                      : state.canDistill
                                      ? '使用注入的蒸馏器（测试）'
                                      : '还没开启云端模型：设置 → RAG 模型 → 使用云端模型',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              FilledButton.icon(
                                onPressed: _busy || !state.canDistill
                                    ? null
                                    : () => _distill(state),
                                icon: _busy
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.auto_fix_high, size: 18),
                                label: Text(_busy ? '蒸馏中…' : '立即蒸馏'),
                              ),
                            ],
                          ),
                          if (_busy) ...<Widget>[
                            const SizedBox(height: 10),
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
                          if (_last != null) ...<Widget>[
                            const SizedBox(height: 8),
                            SelectableText(
                              _last!.file,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _skills.isEmpty
                ? const EmptyState(
                    icon: Icons.auto_fix_high,
                    title: '还没有 skill',
                    description: '打开开关后点「立即蒸馏」；生成的文件在 db/skill/ 下',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _skills.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final skill = _skills[index];
                      return ListTile(
                        leading: const Icon(Icons.workspace_premium_outlined),
                        title: Text(skill.name),
                        subtitle: Text(
                          '${_stamp(skill.createdAt)} · ${skill.model.isEmpty ? '未知模型' : skill.model} · ${skill.bytes} 字节',
                          style: theme.textTheme.labelSmall,
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => _preview(skill),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _preview(SkillEntry skill) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(skill.name),
        content: SizedBox(
          width: 760,
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SelectableText(
                skill.directory,
                style: Theme.of(dialogContext).textTheme.labelSmall,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: MarkdownView(
                    data: skill.markdown,
                    emoji: AppScope.of(context).emojiMap,
                    resolveLocalPath: (_) => null,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: skill.markdown));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(content: Text('已复制 SKILL.md')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}
