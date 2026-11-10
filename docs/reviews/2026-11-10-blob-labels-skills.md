# 提交审查记录 — 2026-11-10 blob 清理 / RAG 来源标签 / skill 更新

**范围**：附加笔记旧 blob 自动清理；RAG 来源主/附前缀；分词与蒸馏 skill 规则更新
**对应需求**：用户三项优化 + 规则选择（自动清理、前缀标记、主+附拆分、notes 字段、附件只读且去重、外部输出完整库）

## 改动
- `app_state.dart`：`saveMarkdownNote` 保存后调用 `deleteUnreferencedBlobs()`。
- `rag_page.dart`：来源 chip 显示「主 / 附」前缀。
- `skills/diary-segmenter/SKILL.md`：一天一个主文件、notes 字段、附加笔记目录、附件只读与跨 md 去重、
  外部 agent 输出完整库目录结构。
- `skills/mdiary-distiller/SKILL.md`（新增）：纳入附加笔记、资料分层（主文件事实/附加笔记细节/不确定项）、
  事实来源标注 `[主 日期]` / `[附 文件名]`。
- `skill_job.dart`：蒸馏提示词增加「资料分层 + 来源标注」。

## 风险
- 清理只删未被任何附件行引用的 blob；并发写/RAG 不受影响；
- RAG 前缀只改来源 chip，回答引用仍是 [日期-标题]（保持模型输出稳定）；
- 分词 skill 的 notes 字段目前只是约定，App 端导入尚未写附加笔记（后续接）；
- 蒸馏 skill 文件与代码提示词是两份，需要同步维护。

## 验证
`flutter analyze` 0 issue；`flutter test` 293 passed（新增 blob 清理断言）。