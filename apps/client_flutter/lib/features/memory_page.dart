import 'package:flutter/material.dart';

import '../rag/memory_chat.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/widgets.dart';

/// 记忆对话（v2.7 第三步）：只用蒸馏 skill，按库持久化。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<MemoryMessage> _messages = const <MemoryMessage>[];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _load() {
    setState(() => _messages = AppScope.of(context).loadMemoryChat());
    _jumpToBottom();
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send(AppState state) async {
    final question = _input.text.trim();
    if (question.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _busy = true;
      _error = null;
      _messages = <MemoryMessage>[
        ..._messages,
        MemoryMessage(
          fromUser: true,
          text: question,
          createdAt: DateTime.now(),
        ),
      ];
    });
    _jumpToBottom();
    try {
      final reply = await state.askMemory(question);
      if (!mounted) return;
      setState(() => _messages = <MemoryMessage>[..._messages, reply]);
      _jumpToBottom();
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
    final skill = state.memorySkillName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆对话'),
        centerTitle: false,
        actions: <Widget>[
          if (_messages.isNotEmpty)
            TextButton(
              onPressed: () {
                state.clearMemoryChat();
                setState(() => _messages = const <MemoryMessage>[]);
              },
              child: const Text('新对话'),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Row(
              children: <Widget>[
                Icon(
                  skill == null ? Icons.warning_amber_rounded : Icons.memory,
                  size: 16,
                  color: skill == null
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    skill == null
                        ? '还没有蒸馏 skill：先到「蒸馏」页生成一份'
                        : '记忆来源：$skill（只用 skill，不检索日记）',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _messages.isEmpty
                ? const EmptyState(
                    icon: Icons.forum_outlined,
                    title: '和「有记忆的自己」聊聊',
                    description: '先蒸馏一份 skill，再在这里对话；对话按库保存',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return Align(
                        alignment: message.fromUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 680),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: message.fromUser
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SelectableText(
                            message.text,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(state),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '问点关于「我」的事，比如「我去年最难忘的旅行」',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _send(state),
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, size: 18),
                  label: Text(_busy ? '思考中…' : '发送'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
