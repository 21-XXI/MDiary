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
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('数据目录'),
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
                  leading: const Icon(Icons.drive_file_move_outline),
                  title: const Text('更改数据目录'),
                  subtitle: const Text(
                    '在资源管理器里选个文件夹，数据库与附件会迁移过去；迁移成功后旧目录会被删除',
                  ),
                  onTap: () => _changeDataRoot(context, state),
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

  /// 选目录 -> 确认 -> 迁移 -> 提示结果。失败时数据仍在旧目录。
  static Future<void> _changeDataRoot(
    BuildContext context,
    AppState state,
  ) async {
    final current = state.dataRootPath;
    final picked = await state.pickDirectory(
      title: '选择新的数据目录（数据库与附件会迁移到这里）',
    );
    if (picked == null || !context.mounted) return;

    final normalized = p.canonicalize(picked);
    if (p.equals(normalized, p.canonicalize(current))) {
      _snack(context, '这已经是当前数据目录');
      return;
    }
    final blocked = DataRootMigration.blockingReason(normalized);
    if (blocked != null) {
      _snack(context, blocked);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('迁移数据目录？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('当前目录：'),
            SelectableText(current),
            const SizedBox(height: 10),
            const Text('迁移到：'),
            SelectableText(normalized),
            const SizedBox(height: 10),
            const Text(
              '会逐文件复制并校验；校验通过后切换到新目录，旧目录随之删除。'
              '迁移过程中请不要在别处写这个库。',
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始迁移'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final result = await state.changeDataRoot(normalized);
      if (context.mounted) {
        _snack(
          context,
          '已迁移 ${result.files} 个文件（${formatBytes(result.bytes)}）到 ${result.target}',
        );
      }
    } catch (error) {
      if (context.mounted) {
        _snack(context, '迁移失败：$error。数据仍在 $current');
      }
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
