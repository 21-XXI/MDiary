# MDiary v2.8.2 发布说明（Windows x64）

发布日期：2026-11-10　｜　版本：`2.8.2+17`　｜　基于 v2.8.1

## 1. 记忆对话
- 没有蒸馏 skill 时正常聊天（不再报错，不检索日记）；
- 右上角可选择「模型默认预设 / 最新 skill / 指定 skill」；
- 模型默认预设：不注入任何角色，完全按模型自带预设对话；
- 选中的 skill 被删后回退默认预设。

## 2. 编辑器
- 长文本软换行（VSCode 风格），不做横向滚动；
- 左侧行号按**逻辑行**显示：软换行续行不编号，回车才进入下一号；当前行号高亮。

## 3. 提示词与 skill
- 蒸馏提示词由 `skills/diary-distiller/SKILL.md` 生成（`tool/gen_skill_prompts.dart`）；
- `verify.ps1` 构建前自动重新生成，避免代码与 skill 漂移；
- 子 md 计入当天字数，显示 `N 字（子 M）`。

## 4. 验证
- `flutter analyze` 0 issue；`flutter test` 297 passed；
- 包 `MDiary-2.8.2-windows-x64.zip`。