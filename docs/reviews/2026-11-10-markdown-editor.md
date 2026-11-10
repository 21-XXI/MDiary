# 提交审查记录 — 2026-11-10 Markdown 编辑器（六项）

**范围**：语法高亮、行号/当前行、自动配对、列表续行/Tab 缩进、查找替换、大纲、命令面板
**对应需求**：用户选择的 VSCode 风格编辑体验（六项全选）

## 改动
- `lib/ui/markdown_editor.dart`（新增）：`highlightMarkdownLine`、`MarkdownEditingController`
  （语法高亮）、`AutoPairFormatter`、`continueListOnEnter`、`indentSelection`、
  `FindReplaceController`、`collectHeadings`、查找/大纲/命令对话框。
- `entry_editor_page.dart`：正文控制器换成高亮控制器；加行号栏与滚动同步；
  快捷键 Ctrl+F/Ctrl+P/Tab/Enter；工具栏「编辑工具」菜单；工具栏图标行改 Wrap 防窄窗口溢出。
- `test/markdown_editor_test.dart`（7 例）：高亮、配对、续行、编号、查找替换、大纲。

## 风险
- 行号栏与软换行不对齐（只按逻辑行计算）；滚动同步用同一个 offset，超长文档可能抖动；
- 高亮是正则级，嵌套强调/多行代码围栏颜色不完整；
- 自动配对对中文输入法组合态未特殊处理；
- 查找替换的「替换」只处理当前选区，需先点「下一个」。

## 验证
`flutter analyze` 0 issue；`flutter test` 291 passed（新增 7）。