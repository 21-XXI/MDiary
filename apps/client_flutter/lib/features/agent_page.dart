import 'package:flutter/material.dart';

import '../rag/agent_config.dart';
import '../state/app_scope.dart';
import '../ui/widgets.dart';

/// Agent 设置（v2.7）：步数上限、工具权限、运行日志。
class AgentPage extends StatefulWidget {
  const AgentPage({super.key});

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  List<AgentRun> _runs = const <AgentRun>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _load() {
    setState(() => _runs = AppScope.of(context).loadAgentRuns());
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final config = state.agentConfig;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 设置'),
        centerTitle: false,
        actions: <Widget>[
          if (_runs.isNotEmpty)
            TextButton(
              onPressed: () {
                state.clearAgentRuns();
                _load();
              },
              child: const Text('清空日志'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('步数上限', style: theme.textTheme.titleSmall),
                  Text(
                    '分词解析失败时最多重试几次；记忆对话目前固定 1 步。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Slider(
                          min: 1,
                          max: 10,
                          divisions: 9,
                          value: config.maxSteps.toDouble(),
                          label: '${config.maxSteps}',
                          onChanged: (value) => state.setAgentConfig(
                            config.copyWith(maxSteps: value.round()),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '${config.maxSteps}',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: <Widget>[

                SwitchListTile(
                  value: config.allowReadSkill,
                  onChanged: (value) => state.setAgentConfig(
                    config.copyWith(allowReadSkill: value),
                  ),
                  title: const Text('读取 skill'),
                  subtitle: const Text('记忆对话使用蒸馏 skill'),
                ),
                SwitchListTile(
                  value: config.allowSearchDiary,
                  onChanged: (value) => state.setAgentConfig(
                    config.copyWith(allowSearchDiary: value),
                  ),
                  title: const Text('检索日记（预留）'),
                  subtitle: const Text('当前记忆对话只用 skill，不检索'),
                ),
                SwitchListTile(
                  value: config.logEnabled,
                  onChanged: (value) => state.setAgentConfig(
                    config.copyWith(logEnabled: value),
                  ),
                  title: const Text('记录运行日志'),
                  subtitle: const Text('存在 <库>/agent/runs.jsonl'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text('最近运行', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          if (_runs.isEmpty)
            const EmptyState(
              icon: Icons.receipt_long_outlined,
              title: '还没有运行记录',
              description: '分词或记忆对话跑一次后，这里会出现日志',
            )
          else
            for (final run in _runs.reversed)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  run.ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 18,
                  color: run.ok
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                title: Text(
                  '${_kind(run.kind)} · ${run.steps} 步',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  '${_time(run.startedAt)} · ${run.message}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
        ],
      ),
    );
  }

  static String _kind(String kind) => switch (kind) {
    'segment' => '分词',
    'memory' => '记忆对话',
    _ => kind,
  };

  static String _time(DateTime time) =>
      '${time.month}-${time.day} ${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
