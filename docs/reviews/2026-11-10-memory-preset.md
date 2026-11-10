# 提交审查记录 — 2026-11-10 记忆对话可选「模型默认预设」

**范围**：把模型原本的预设当成一个可选 skill；选中它时不注入任何角色，直接按模型默认预设对话
**对应需求**：用户「记忆对话时添加模型本来的预设为 skill，这样可以通过选择该 skill 和模型本来对话」

## 改动
- `app_state`：新增 `memoryModelPreset` / `memoryLatestSkill` 两个哨兵值，`memory_skill` 存 meta；
  `memorySkillSelection` / `setMemorySkill` / `memorySkillName` / `_memorySkillMarkdown`；
  `askMemory` 按选择解析 skill，找不到回退模型默认预设。
- `memory_page`：右上角新增「选择 skill」菜单（模型默认预设 / 最新 skill / 各 skill）；
  顶部显示当前记忆来源。
- `memory_chat.buildMemoryPrompt`：skill 为空时**不写任何角色与规则**，只发历史 + 问题。
- 测试：无 skill 提示词不含「记忆助手」；默认预设可切换且按库保存。

## 风险
- 默认仍是「最新 skill」，需要用户手动切到模型默认预设；
- 选中的 skill 被删后回退默认预设，界面会提示；
- 选择存 meta（按库独立）。

## 验证
`flutter analyze` 0 issue；`flutter test` 297 passed。