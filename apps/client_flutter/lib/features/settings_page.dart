import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/formatters.dart';
import '../data/data_root_migration.dart';
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
          const SectionLabel('数据'),
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
                  subtitle: SelectableText(
                    state.dataRootPath,
                    style: theme.textTheme.bodySmall,
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
                      Text(
                        '附件字节存在数据库里；这里是预览/打开用的缓存，删掉会自动重建',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: '在资源管理器中打开',
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => state.openInSystem(state.attachmentsPath),
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
              title: const Text('MDiary v1.0.0'),
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