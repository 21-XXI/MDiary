# 提交审查记录 — 2026-11-10 导航收拢 / RAG 引用跳转 / 蒸馏预览

**范围**：导航栏 4 常用 + 更多菜单；回答里的 `[日期-标题]` 可点击；蒸馏改为预览后保存
**对应需求**：用户四项优化中的 1、2、4（第 3 项 Markdown 编辑器另行实施）

## 改动
- `home_page.dart`：主栏只留 星图 / RAG / 记忆对话 / 设置，分词导入、蒸馏、Agent 设置、回收站收进「更多」菜单。
- `rag_page.dart`：回答文本改为 `Text.rich`，匹配 `[日期-标题]` 并映射到来源，点击调用 `_openHit`；
  来源 chip 行为不变；识别器在「新对话」时释放。
- `skill_job.dart`：`preview()` 只生成不落盘，`save()` 落盘；`run()` = preview + save。
- `app_state.dart`：`previewSkill()` / `saveSkill()`。
- `skill_page.dart`：先预览（Markdown 对话框），确认后保存；预览期间暂停进度动画。
- `test/rag_ui_test.dart`：蒸馏用例改走「更多」菜单并确认预览对话框。

## 风险
- 引用识别只匹配来源里存在的标题（模型写错标题不会变成链接）；
- 富文本不可选中（回退到无来源时仍可选中）；
- 蒸馏预览时若要关闭页面，对话框会拦截；
- `save()` 的 meta 里 `soul_bytes` 暂记 0（预览后保存拿不到 soul 原文长度）。

## 验证
`flutter analyze` 0 issue；`flutter test` 284 passed（问答引用、蒸馏预览、导航用例均更新）。