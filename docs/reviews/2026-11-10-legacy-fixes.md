# 提交审查记录 — 2026-11-10 遗留问题修复（A/B 部分/D/E/F/G）

**范围**：分词解耦 Agent；子笔记重命名同步；子笔记索引防抖；模型 temperature/num_ctx 生效 + 测试连接；
Ctrl+N 一天一篇；文档口径更新

## 改动
- `app_state`：分词去掉 allowReadFolder/allowCreateLibrary/allowWriteDiary 权限拦截；
  子笔记保存改为 5 秒防抖重建索引（`_scheduleRagReindex`，dispose 取消）；
  `testModelProfile`；按 profile 传 temperature/num_ctx。
- `agent_page`：移除分词相关的三个开关（只保留记忆对话读取 skill / 检索预留 / 日志 / 步数）。
- `home_page`：Ctrl+N 也走一天一篇的 `_newEntry`。
- `answer.dart` / `cloud_client.dart`：`temperature`、`num_ctx` 真正进请求。
- `attachment_repository` / `saveMarkdownNote`：重命名时更新附件 filename，并把主文件链接文字同步。
- `settings_page`：每个模型配置加「测试连接」。
- 测试：Ctrl+N 改为「一天一篇」断言。
- 文档：markdown/rag/segmenter 更新到 2.8.2 实际行为。

## 未完成
- B 的「分词 notes 中引用的附件复制并重写」尚未做（只做了重命名同步），需要单独一轮。

## 风险
- 防抖 5 秒内连续保存只索引一次，期间检索可能读旧索引；
- 测试连接对 Ollama 只校验模型列表，不实际推理；
- Ctrl+N 现在不再支持同一天多篇（旧数据仍保留）。

## 验证
`flutter analyze` 0 issue；`flutter test` 297 passed。