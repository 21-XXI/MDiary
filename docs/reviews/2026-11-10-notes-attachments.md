# 提交审查记录 — 2026-11-10 分词 notes 附件复制

**范围**：分词导入时，notes 正文引用的本地附件会被复制进库并改写为 `assets/<sha>.<ext>`
**对应需求**：用户「继续修 notes 附件（开发中），C 不考虑」

## 改动
- `importSegmentPlan` 的 note 处理：先用正则收集 `![...](ref)` / `[...](ref)` 中的本地引用，
  在源目录按文件名查找 → `store.storeFile` → 插入附件并按 sha 去重引用；
- 改写后的 note 正文再作为 `text/x-mdiary-note` 附件保存；
- 远程链接与已有 `assets/` 引用不处理。

## 风险
- 引用按 basename 匹配，同名不同目录取第一个；
- 同一附件被多条 note 引用会插入多条附件行（blob 共享，不重复占空间）；
- 尚未有端到端导入测试（依赖建库流程），目前只保证分析与现有用例通过。

## 验证
`flutter analyze` 0 issue；`flutter test` 297 passed。