# 提交审查记录 — 2026-11-10 skill 目录统一 / 子笔记与附件区分

**范围**：蒸馏 skill 与分词 skill 放同一目录并加维护约定；附加 md 用独立 mime，界面区分「主 / 子 / 附件」

## 改动
- `skills/mdiary-distiller` → `skills/diary-distiller`，与 `diary-segmenter` 命名/结构对齐；
- 新增 `skills/README.md`：两个 skill 的用途 + 「蒸馏提示词必须与 SKILL.md 同步」的维护约定；
- 附加 md 的 mime 改为 `text/x-mdiary-note`（新建与分词 notes 导入都用它）；
- RAG 来源标签：`主 / 子 / 附件`（`.md` 附件算「子」，其余算「附件」）；
- 编辑器附件条：`.md` 显示「子 · 文件名」，其他显示「附件 · 文件名」。

## 风险
- 旧数据里的附加 md 还是 `text/markdown`，界面按文件后缀仍能识别为「子」；mime 只在新建时生效；
- 「子」的判定依赖 `.md` 后缀，重命名为非 md 会退回「附件」；
- 蒸馏提示词仍是代码常量，靠 README 约定与测试防漂移（尚未做自动同步）。

## 验证
`flutter analyze` 0 issue；`flutter test` 294 passed（note 用例断言新 mime）。