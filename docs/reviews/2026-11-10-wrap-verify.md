# 提交审查记录 — 2026-11-10 软换行 / 去行号 / verify 前置生成

**范围**：长文本软换行、编辑器去掉行号；verify.ps1 构建前生成提示词
**对应需求**：用户「长文本换行按 VSCode 一样，不显示行数，生成脚本加进 verify.ps1」

## 改动
- `entry_editor_page`：移除左侧行号栏与滚动同步/控制器；`TextField` 恢复单列、按宽度软换行
  （`maxLines: null` + `expands: true`），其余高亮/配对/缩进/快捷键保留。
- `scripts/verify.ps1`：在 `pub get` 前调用 `dart run tool/gen_skill_prompts.dart`，
  生成失败直接中止。
- 补回 `_openAttachment`（上一轮替换时误删）。

## 风险
- 去掉行号后无法直观定位行；查找/大纲仍可定位；
- 软换行时长行不缩进（与编辑器一致，VSCode 也如此）；
- verify 依赖 flutter 自带 dart 路径，换环境若找不到 dart 会失败。

## 验证
`flutter analyze` 0 issue；`flutter test` 295 passed。