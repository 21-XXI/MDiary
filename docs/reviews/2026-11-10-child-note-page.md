# 提交审查记录 — 2026-11-10 子 md 全屏编辑 + 提示词同步

**范围**：蒸馏提示词与 SKILL.md 同步校验；子 md 入口改名；子 md 用与主文件一致的全屏编辑器；子/附件显示区分

## 改动
- 新增 `test/skill_prompt_sync_test.dart`：校验 `CloudSkillDistiller.buildPrompt` 与
  `skills/diary-distiller/SKILL.md` 都包含六节结构、资料分层、来源标注；缺一即失败。
- 工具栏按钮「附加 md 笔记」→「添加子 md 文件」。
- 新增 `lib/features/child_note_page.dart`：全屏编辑（语法高亮、预览切换、符号/表情/查找/大纲、保存）。
- `entry_editor_page`：子 md 改为 push 全屏页；附件条对 `.md` 用 `description_outlined` 图标并标「子」，
  其他附件标「附件」。

## 风险
- 子 md 页的「大纲」临时 FocusNode 未释放（小泄漏）；
- 提示词是代码常量，靠测试防漂移，还不是运行时读文件；
- 子 md 不参与当天字数，预览中链接仍以附件形式展示。

## 验证
`flutter analyze` 0 issue；`flutter test` 295 passed（新增 1）。