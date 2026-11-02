import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
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
                  title: const Text('附件目录'),
                  subtitle: SelectableText(
                    state.attachmentsPath,
                    style: theme.textTheme.bodySmall,
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

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }
}
