import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/formatters.dart';
import '../data/data_root_migration.dart';
import '../core/secret_store.dart';
import '../rag/rag_settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../ui/widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: <Widget>[
          const SectionLabel('外观'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('跟随系统'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                    ),
                  ],
                  selected: <ThemeMode>{state.themeMode},
                  onSelectionChanged: (selection) =>
                      state.setThemeMode(selection.first),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Text('编辑器字号'),
                      const Spacer(),
                      Text(
                        '${state.editorFontSize.round()}',
                        style: theme.textTheme.labelLarge,
                      ),
                    ],
                  ),
                  Slider(
                    min: 12,
                    max: 28,
                    divisions: 16,
                    value: state.editorFontSize,
                    label: '${state.editorFontSize.round()}',
                    onChanged: state.setEditorFontSize,
                  ),
                  Text(
                    '正文以等宽字体显示，便于对齐 Markdown 结构',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SectionLabel('RAG 模型'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: _RagModelsCard(state: state),
            ),
          ),          const SectionLabel('数据'),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('当前库'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SelectableText(
                        state.libraryPath,
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        '库里是日记 + 附件字节；换目录就是换一个库（不同用户的库）',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: '在资源管理器中打开',
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => state.openInSystem(state.libraryPath),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('切换 / 新建库'),
                  subtitle: const Text(
                    '选一个装着 mdiary.sqlite 的目录；空目录会新建一个空库',
                  ),
                  onTap: () => _switchLibrary(context, state),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.library_add_outlined),
                  title: const Text('导入新库'),
                  subtitle: const Text(
                    '从目录里选一个 .sqlite / .db，作为新库导入并切换过去',
                  ),
                  onTap: () => _importLibrary(context, state),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('备份数据库'),
                  subtitle: Text(_lastBackupLabel(state)),
                  onTap: () => _backupDatabase(context, state),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.compress),
                  title: const Text('压缩数据库'),
                  subtitle: const Text('删除大量日记/附件后回收文件空间（VACUUM）'),
                  onTap: () => _compactDatabase(context, state),
                ),                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: const Text('标签管理'),
                  subtitle: const Text('重命名 / 删除标签，并查看每个标签的篇数'),
                  onTap: () => _manageTags(context, state),
                ),                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.merge_type),
                  title: const Text('合并库'),
                  subtitle: const Text(
                    '把另一个库按 id 合并进来（同 id 保留较新的，附件按内容去重）',
                  ),
                  onTap: () => _mergeLibrary(context, state),
                ),
                if (state.dataRootNotice != null) ...<Widget>[
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.error,
                    ),
                    title: const Text('数据未存放在首选位置'),
                    subtitle: Text(
                      '首选目录不可写，已自动改用上面的目录。'
                      '原因：${state.dataRootNotice}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('程序数据目录'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SelectableText(
                        state.dataRootPath,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (state.dataRootSourceLabel.isNotEmpty)
                        Text(
                          state.dataRootSourceLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: '在资源管理器中打开',
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => state.openInSystem(state.dataRootPath),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('附件缓存'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SelectableText(
                        state.attachmentsPath,
                        style: theme.textTheme.bodySmall,
                      ),
                      FutureBuilder<int>(
                        future: state.attachmentCacheBytes(),
                        builder: (context, snapshot) {
                          final size = snapshot.data;
                          return Text(
                            '${size == null ? '' : '占用 ${formatBytes(size)}；'}'
                            '字节在数据库里，缓存删掉会自动重建',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: '缓存操作',
                    onSelected: (value) {
                      if (value == 'open') {
                        state.openInSystem(state.attachmentsPath);
                      } else if (value == 'clear') {
                        _clearAttachmentCache(context, state);
                      }
                    },
                    itemBuilder: (menuContext) => const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'open',
                        child: Text('在资源管理器中打开'),
                      ),
                      PopupMenuItem<String>(
                        value: 'clear',
                        child: Text('清空缓存'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清理孤儿附件'),
                  subtitle: const Text('删除回收站之外、没有任何日记引用的附件文件'),
                  onTap: () async {
                    final removed = await state.collectGarbage();
                    if (context.mounted) {
                      _snack(
                        context,
                        removed == 0 ? '没有可清理的附件' : '已清理 $removed 个附件文件',
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SectionLabel('导入 / 导出'),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('整库导出'),
                  subtitle: const Text(
                    '每篇一个 .md，附件放入 assets/，可直接用 Typora / VS Code 打开',
                  ),
                  onTap: () async {
                    final result = await state.exportLibrary();
                    if (result != null && context.mounted) {
                      _snack(
                        context,
                        '已导出 ${result.entries} 篇日记到 ${result.directory}',
                      );
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.file_upload_outlined),
                  title: const Text('从目录导入 .md'),
                  subtitle: const Text('递归扫描目录；相同正文 + 日期视为重复并跳过'),
                  onTap: () async {
                    final result = await state.importLibrary();
                    if (result == null || !context.mounted) return;
                    final errors = result.errors.isEmpty
                        ? ''
                        : '，${result.errors.length} 个文件失败';
                    _snack(
                      context,
                      '导入 ${result.imported} 篇，跳过重复 ${result.skipped} 篇$errors',
                    );
                  },
                ),
              ],
            ),
          ),
          const SectionLabel('快捷键'),
          Card(
            child: Column(
              children: const <Widget>[
                ListTile(
                  dense: true,
                  leading: Icon(Icons.add),
                  title: Text('新建日记'),
                  trailing: Text('Ctrl + N'),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.save_outlined),
                  title: Text('立即保存'),
                  trailing: Text('Ctrl + S'),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.search),
                  title: Text('聚焦搜索'),
                  trailing: Text('Ctrl + F'),
                ),
              ],
            ),
          ),
          const SectionLabel('关于'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('MDiary v1.1.1'),
              subtitle: Text(
                'Markdown 日记 · 本地 SQLite 存储 · 附件内容寻址\n'
                '运行于 ${Platform.operatingSystem} ${Platform.version.split(' ').first}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 切换库：优先给最近用过的库，也可以选任意目录（空目录会新建空库）。
  static Future<void> _switchLibrary(
    BuildContext context,
    AppState state,
  ) async {
    const pickOther = '__pick__';
    final recent = state.recentLibraries;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('切换库'),
        children: <Widget>[
          for (final dir in recent)
            ListTile(
              leading: const Icon(Icons.storage),
              title: Text(p.basename(dir)),
              subtitle: Text(
                dir,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              selected: p.equals(dir, state.libraryPath),
              onTap: () => Navigator.of(dialogContext).pop(dir),
            ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('选择其他目录…'),
            onTap: () => Navigator.of(dialogContext).pop(pickOther),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    var target = choice;
    if (choice == pickOther) {
      final dir = await state.pickDirectory(
        title: '选择库目录（里面放 mdiary.sqlite；空目录会新建库）',
      );
      if (dir == null || !context.mounted) return;
      target = dir;
    }
    await _doSwitchLibrary(context, state, target);
  }

  static Future<void> _doSwitchLibrary(
    BuildContext context,
    AppState state,
    String dir,
  ) async {
    final hasDatabase = File(
      p.join(dir, DataRootMigration.databaseName),
    ).existsSync();
    if (!hasDatabase) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('这个目录里没有库'),
          content: Text('「$dir」里没有 mdiary.sqlite。\n要在这里新建一个空库并切换过去吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('新建并切换'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    try {
      await state.switchLibrary(dir);
      if (context.mounted) _snack(context, '已切换到库：${p.basename(dir)}');
    } catch (error) {
      if (context.mounted) _snack(context, '切换失败：$error');
    }
  }

  /// 导入新库：选目录 -> 选一个 .sqlite -> 起名字 -> 复制成新库并切换。
  static Future<void> _importLibrary(
    BuildContext context,
    AppState state,
  ) async {
    final directory = await state.pickDirectory(
      title: '选择包含数据库文件（.sqlite / .db）的目录',
    );
    if (directory == null || !context.mounted) return;
    final candidates = _findDatabaseFiles(Directory(directory));
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      _snack(context, '目录里没有 .sqlite / .db 文件');
      return;
    }
    final picked = await _pickDatabaseFile(
      context,
      '选择要导入为新库的文件',
      candidates,
    );
    if (picked == null || !context.mounted) return;

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _NameDialog(
        title: const Text('新库名字'),
        initial: p.basenameWithoutExtension(picked),
        hintText: '例如：张三 / 家庭 / 2026',
        confirmLabel: '导入',
      ),
    );
    if (name == null || !context.mounted) return;

    try {
      final newDir = await state.importDatabaseAsLibrary(
        picked,
        folderName: name,
      );
      if (context.mounted) {
        _snack(context, '已导入为新库：${p.basename(newDir)}');
      }
    } catch (error) {
      if (context.mounted) _snack(context, '导入失败：$error');
    }
  }

  /// 合并库：选目录 -> 选一个 .sqlite -> 确认 -> 合并进当前库。
  static Future<void> _mergeLibrary(
    BuildContext context,
    AppState state,
  ) async {
    final directory = await state.pickDirectory(
      title: '选择要合并进来的库所在目录',
    );
    if (directory == null || !context.mounted) return;
    final candidates = _findDatabaseFiles(Directory(directory));
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      _snack(context, '目录里没有 .sqlite / .db 文件');
      return;
    }
    final picked = await _pickDatabaseFile(
      context,
      '选择要合并进当前库的文件',
      candidates,
    );
    if (picked == null || !context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('合并到这个库？'),
        content: Text(
          '把「${p.basename(picked)}」合并进当前库（${p.basename(state.libraryPath)}）：\n\n'
          '· 按日记 id 合并，同 id 保留更新时间较新的；\n'
          '· 附件按内容哈希去重，重复内容不占第二份；\n'
          '· 标签按名字合并；\n'
          '· 源库不会被修改。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('合并'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final result = await state.mergeLibrary(picked);
      if (context.mounted) {
        _snack(
          context,
          '合并完成：新增 ${result.added} 篇、更新 ${result.updated} 篇、'
          '附件 ${result.attachmentsAdded} 个（新增字节 ${result.blobsAdded} 份）',
        );
      }
    } catch (error) {
      if (context.mounted) _snack(context, '合并失败：$error');
    }
  }

  static Future<String?> _pickDatabaseFile(
    BuildContext context,
    String title,
    List<File> files,
  ) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: <Widget>[
          for (final file in files)
            ListTile(
              leading: const Icon(Icons.storage),
              title: Text(p.basename(file.path)),
              subtitle: Text(
                '${formatBytes(file.lengthSync())} · '
                '${formatDateTime(file.lastModifiedSync())}',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              onTap: () => Navigator.of(dialogContext).pop(file.path),
            ),
        ],
      ),
    );
  }

  /// 目录里可能放着一批备份：只挑出像数据库的文件，按修改时间倒序。
  static List<File> _findDatabaseFiles(Directory directory) {
    const maxFiles = 50;
    final result = <File>[];
    if (!directory.existsSync()) return result;
    try {
      for (final entity in directory.listSync(recursive: true, followLinks: false)) {
        if (result.length >= maxFiles) break;
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (name.endsWith('-wal') ||
            name.endsWith('-shm') ||
            name.endsWith('-journal') ||
            name.contains('.bak-') ||
            name.endsWith('.bak')) {
          continue;
        }
        if (!(name.endsWith('.sqlite') ||
            name.endsWith('.sqlite3') ||
            name.endsWith('.db'))) {
          continue;
        }
        result.add(entity);
      }
    } on Object {
      return result;
    }
    result.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return result;
  }

  /// 标签管理：重命名（合并到已有名字）或删除（只解除标记）。
  static Future<void> _manageTags(BuildContext context, AppState state) async {
    if (state.tagCounts.isEmpty) {
      _snack(context, '还没有标签');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('标签管理'),
        content: SizedBox(
          width: 420,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              final counts = state.tagCounts.entries.toList();
              return ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final item in counts)
                    ListTile(
                      dense: true,
                      title: Text(item.key),
                      subtitle: Text('${item.value} 篇'),
                      trailing: PopupMenuButton<String>(
                        tooltip: '操作',
                        onSelected: (action) async {
                          if (action == 'rename') {
                            final renamed = await showDialog<String>(
                              context: context,
                              builder: (nameContext) => _NameDialog(
                                title: const Text('重命名标签'),
                                initial: item.key,
                                hintText: '新名字（与已有标签同名会合并）',
                                confirmLabel: '重命名',
                              ),
                            );
                            if (renamed == null || renamed.trim().isEmpty) {
                              return;
                            }
                            await state.renameTag(item.key, renamed);
                          } else if (action == 'delete') {
                            await state.removeTag(item.key);
                          }
                          setDialogState(() {});
                        },
                        itemBuilder: (menuContext) =>
                            const <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Text('重命名'),
                          ),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
  static String _lastBackupLabel(AppState state) {
    final backups = state.listBackups();
    if (backups.isEmpty) return '还没有备份；点一下生成快照（自动保留最近 7 份）';
    final last = backups.first;
    return '最近备份：${formatDateTime(last.lastModifiedSync())}'
        '（${formatBytes(last.lengthSync())}）';
  }

  static Future<void> _backupDatabase(
    BuildContext context,
    AppState state,
  ) async {
    try {
      final path = await state.backupDatabase();
      if (!context.mounted) return;
      _snack(
        context,
        '已备份：${p.basename(path)}（${formatBytes(File(path).lengthSync())}）',
      );
    } catch (error) {
      if (context.mounted) _snack(context, '备份失败：$error');
    }
  }

  static Future<void> _compactDatabase(
    BuildContext context,
    AppState state,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('压缩数据库？'),
        content: const Text('会整理数据库文件、释放已删除内容占用的空间，内容不变。'
            '数据量大时界面会短暂无响应。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('压缩'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final (before, after) = await state.compactDatabase();
      if (!context.mounted) return;
      _snack(context, '已压缩：${formatBytes(before)} → ${formatBytes(after)}');
    } catch (error) {
      if (context.mounted) _snack(context, '压缩失败：$error');
    }
  }

  static Future<void> _clearAttachmentCache(
    BuildContext context,
    AppState state,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空附件缓存？'),
        content: const Text('附件字节都在数据库里，缓存只是预览/打开用的副本；'
            '清空后第一次预览会重新生成。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final freed = await state.clearAttachmentCache();
      if (!context.mounted) return;
      _snack(context, '已清空附件缓存，释放 ${formatBytes(freed)}');
    } catch (error) {
      if (context.mounted) _snack(context, '清空失败：$error');
    }
  }
  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }
}

/// 起名字的小对话框：自己管 controller，避免对话框退场时 controller 已被 dispose。
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.hintText,
    required this.confirmLabel,
  });

  final Widget title;
  final String initial;
  final String hintText;
  final String confirmLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: widget.title,
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hintText),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 设置页里的 RAG 模型选择：交互模型（问答）/ 生成模型（摘要、日报、soul）/ 向量模型。
class _RagModelsCard extends StatefulWidget {
  const _RagModelsCard({required this.state});

  final AppState state;

  @override
  State<_RagModelsCard> createState() => _RagModelsCardState();
}

class _RagModelsCardState extends State<_RagModelsCard> {
  List<String> _models = const <String>[];
  bool _loading = true;
  bool _saved = false;
  String? _cloudStatus;

  late final TextEditingController _cloudBase = TextEditingController(
    text: widget.state.ragSettings.cloudBaseUrl,
  );
  late final TextEditingController _cloudModel = TextEditingController(
    text: widget.state.ragSettings.cloudModel,
  );
  late final TextEditingController _cloudKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    _detect();
  }

  @override
  void dispose() {
    _cloudBase.dispose();
    _cloudModel.dispose();
    _cloudKey.dispose();
    super.dispose();
  }

  Future<void> _toggleCloud(bool enabled) async {
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('开启云端模型？'),
          content: const Text(
            '开启后，问答的问题与命中的日记片段、以及每日摘要/日报/灵魂档案的输入，'
            '都会发送到你填写的云端服务。\n\n'
            '· API Key 只存本机，用 Windows DPAPI 加密；\n'
            '· 向量索引仍在本地，不上传；\n'
            '· 随时可以关掉这个开关，关掉后不再上送。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('我了解，开启'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    widget.state.updateRagSettings(
      widget.state.ragSettings.copyWith(cloudEnabled: enabled),
    );
    setState(() {
      _saved = true;
      _cloudStatus = enabled ? '已开启云端（内容会发送到云端）' : '已关闭云端';
    });
  }

  void _saveCloudFields() {
    widget.state.updateRagSettings(
      widget.state.ragSettings.copyWith(
        cloudBaseUrl: _cloudBase.text.trim().isEmpty
            ? RagSettings.defaultCloudBaseUrl
            : _cloudBase.text.trim(),
        cloudModel: _cloudModel.text.trim().isEmpty
            ? RagSettings.defaultCloudModel
            : _cloudModel.text.trim(),
      ),
    );
    if (_cloudKey.text.trim().isNotEmpty) {
      widget.state.setCloudApiKey(_cloudKey.text.trim());
      _cloudKey.clear();
    }
    setState(() {
      _saved = true;
      _cloudStatus = '已保存';
    });
  }

  void _clearCloudKey() {
    widget.state.setCloudApiKey('');
    setState(() {
      _saved = true;
      _cloudStatus = '已清除 API Key';
    });
  }

  Future<void> _testCloud() async {
    setState(() => _cloudStatus = '正在测试…');
    final error = await widget.state.testCloud();
    if (!mounted) return;
    setState(() => _cloudStatus = error ?? '连接正常');
  }

  Future<void> _detect() async {
    setState(() => _loading = true);
    try {
      final models = await widget.state.installedModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _update(RagSettings next) {
    widget.state.updateRagSettings(next);
    setState(() => _saved = true);
  }

  List<String> _options(String current) => <String>{
    current,
    ..._models,
  }.where((item) => item.isNotEmpty).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.state.ragSettings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _loading
                    ? '正在检测本机 Ollama 模型…'
                    : _models.isEmpty
                    ? '没检测到模型（Ollama 是否在运行？）'
                    : '已检测到 ${_models.length} 个模型',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _loading ? null : _detect,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新检测'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: settings.askModel,
          decoration: const InputDecoration(
            labelText: '交互模型（问答）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<String>>[
            for (final name in _options(settings.askModel))
              DropdownMenuItem<String>(value: name, child: Text(name)),
          ],
          onChanged: (value) {
            if (value == null) return;
            _update(settings.copyWith(askModel: value));
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: settings.generateModel,
          decoration: const InputDecoration(
            labelText: '生成模型（摘要 / 日报 / soul）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<String>>[
            for (final name in _options(settings.generateModel))
              DropdownMenuItem<String>(value: name, child: Text(name)),
          ],
          onChanged: (value) {
            if (value == null) return;
            _update(settings.copyWith(generateModel: value));
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: settings.embedModel,
          decoration: const InputDecoration(
            labelText: '向量模型（索引）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<String>>[
            for (final name in _options(settings.embedModel))
              DropdownMenuItem<String>(value: name, child: Text(name)),
          ],
          onChanged: (value) {
            if (value == null) return;
            _update(settings.copyWith(embedModel: value));
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: settings.baseUrl,
          decoration: const InputDecoration(
            labelText: 'Ollama 地址',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onFieldSubmitted: (value) {
            if (value.trim().isEmpty) return;
            _update(settings.copyWith(baseUrl: value.trim()));
          },
        ),
        const SizedBox(height: 8),
        Text(
          '改完立即生效，保存在数据目录的 settings.json；换交互模型会影响问答速度，'
          '换生成模型会影响摘要/日报/灵魂档案。向量模型变了会自动重建索引。',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.cloudEnabled,
          onChanged: (value) => _toggleCloud(value),
          title: const Text('使用云端模型（隐私开关）'),
          subtitle: Text(
            settings.cloudEnabled
                ? '问答/摘要/日报/soul 会发送到 ${settings.cloudBaseUrl}'
                : '默认全本地；开启后内容会离开本机',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (settings.cloudEnabled) ...<Widget>[
          const SizedBox(height: 4),
          TextFormField(
            controller: _cloudBase,
            decoration: const InputDecoration(
              labelText: '云端地址（OpenAI 兼容）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _cloudModel,
            decoration: const InputDecoration(
              labelText: '云端模型（如 gpt-4o-mini）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _cloudKey,
            obscureText: true,
            decoration: InputDecoration(
              labelText: settings.hasCloudKey
                  ? 'API Key（已保存，留空则不修改）'
                  : 'API Key',
              isDense: true,
              border: const OutlineInputBorder(),
              helperText: SecretStore.isSecure
                  ? '用 Windows DPAPI 加密保存，只有当前用户能解开'
                  : '当前平台没有系统密钥环，暂用 Base64（不安全）',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.tonal(
                onPressed: _saveCloudFields,
                child: const Text('保存'),
              ),
              TextButton(
                onPressed: settings.hasCloudKey ? _clearCloudKey : null,
                child: const Text('清除 Key'),
              ),
              TextButton(
                onPressed: _testCloud,
                child: const Text('测试连接'),
              ),
            ],
          ),
          if (_cloudStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _cloudStatus!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
        if (_saved)
          Text(
            '已保存',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
      ],
    );
  }
}