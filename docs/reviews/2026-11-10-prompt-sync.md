# 提交审查记录 — 2026-11-10 子 md 字数 / FocusNode / 提示词同源

**范围**：子 md 计入当天字数；子 md 页 FocusNode 释放；蒸馏提示词由 SKILL.md 生成

## 改动
- `entry_editor_page`：footer 字数 = 主文件 + `.md` 子笔记，显示「N 字（子 M）」。
- `child_note_page`：`_outlineFocus` 作为 state 字段并在 dispose 释放。
- 新增 `tool/gen_skill_prompts.dart`：从 `skills/diary-distiller/SKILL.md` 生成
  `lib/rag/skill_prompts.g.dart`；`CloudSkillDistiller.buildPrompt` 直接拼该常量。
- `skill_prompt_sync_test` 继续守护六节结构与资料分层。

## 风险
- 字数统计每次构建要读所有子笔记 blob（大笔记会慢）；已按后缀过滤；
- 生成文件需在改 skill 后手动重跑脚本（测试只校验关键规则，不校验全文）；
- 子笔记字数含 Markdown 标记。

## 验证
`flutter analyze` 0 issue；`flutter test` 295 passed。