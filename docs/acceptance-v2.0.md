# v2.0 验收清单

对应 `docs/project.md` 第 3/4 节与 `docs/rag.md`。执行环境：Windows 10/11 x64，
`flutter build windows --release --no-tree-shake-icons` 产物。版本：**2.0.0**（2026-11-06）。

> 状态列：`PASS` / `FAIL`（附现象）/ `BLOCKED`；标「自动」的由 `flutter test` 覆盖。
> v1.1.1 及更早的验收记录见 git 历史中的 `acceptance-v1.1.md`。

## A. 编译与质量门槛

| # | 项 | 命令 | 期望 | 状态 |
|---|---|---|---|---|
| A1 | 静态分析 | `flutter analyze` | 0 issue | **PASS**（2026-11-06，0 issue） |
| A2 | 单元/界面测试 | `flutter test` | 全绿 | **PASS**（228 passed） |
| A3 | Release 构建 | `scripts\build.ps1` | 产出 exe | **PASS**（Release 目录 21.9 MB） |
| A4 | 冒烟 | `scripts\smoke.ps1` | 启动建库 + 单实例 | **PASS**（verify.ps1 自动执行） |
| A5 | 交付校验 | `SHA256SUMS.txt` | 与 zip 一致 | **PASS**（`MDiary-2.0.0-windows-x64.zip`） |

## B. 书写 / 存储（v1.1.1 能力回归）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| B1 | 新建/自动保存 | Ctrl+N 输入后停 1 s | 显示「已保存」 | **自动**：防抖落库用例 |
| B2 | 重开不丢 | 关闭再开 | 内容完整 | **自动**：`persistence_test` |
| B3 | 中文输入 | 中英混排 | 无乱码丢字 | 人工 |
| B4 | 导出 | 单篇 / 整库 | `.md` + `assets/`，附件名可读 | **自动**：`data_layer_test`、`polish_test` |
| B5 | 多库 | 切换 / 新建 / 导入 / 合并 | 互不污染、按 id 合并 | **自动**：`library_test` |
| B6 | 附件 | 插入/拖拽/粘贴/100 MB 上限 | 字节入库、导出按原文件 | **自动**：`attachment_blob_test` 等 |
| B7 | 备份/压缩/缓存 | 设置 → 备份/压缩/附件缓存 | 生成快照、体积不增、缓存可重建 | **自动**：`polish_test` |
| B8 | 检索 | 搜索标题/正文/标签 | 中文子串命中、高亮 | **自动**：`app_widget_test` |

## C. RAG 索引（2.0.1）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| C1 | 建索引 | 设置/CLI `--reindex` | `rag/index.sqlite` 生成，切片带标题/日期/标签 | **自动**：`rag_index_test` |
| C2 | 增量 | 再跑一次 | 未改动全部跳过 | **自动**：`rag_index_test` |
| C3 | 换模型 | 换 embedding 模型 | 自动清空重建 | **自动**：`rag_index_test` |
| C4 | 附件索引 | 文本附件 | 文件名与正文都可检索 | **自动**：`rag_index_test` |
| C5 | 混合检索 | 搜关键词 | 返回日记/附件、分数、片段 | **自动**：`rag_index_test` |

## D. 每日语义管理（2.0.4）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| D1 | 首次运行 | 启动 5 s 后 | 给所有日记写摘要，`job=done` | **自动**：`rag_daily_test` |
| D2 | 同日再跑 | 再启动 | 跳过（今天已整理） | **自动**：`rag_daily_test` |
| D3 | 只算改动 | 改一篇后触发 | 只重建这一篇 | **自动**：`rag_daily_test` |
| D4 | 标签建议 | 看 `entry_summary` | 只建议、不改用户标签 | **自动**：`rag_daily_test` |
| D5 | 模型不可用 | 关掉 Ollama | 任务 failed、不写 `last_daily_run`、下次重试 | **自动**：`rag_daily_test` |

## E. 日报（2.0.5）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| E1 | 空日 | 没有日记的一天 | 生成「这一天没有写日记」 | **自动**：`rag_report_test` |
| E2 | 有内容 | 两三篇日记 | 三段式 + `[日期-标题]` 引用 + 附件名 | **自动**：`rag_report_test` |
| E3 | 补全 | 启动/RAG 页「补全缺失」 | 补到昨天，今天不自动生成 | **自动**：`rag_report_test` |
| E4 | 模型失败 | 模型报错 | 退化为离线骨架，仍写文件 | **自动**：`rag_report_test` |
| E5 | 连续空日 | 多天空白 | 提示「连续 N 天没有记录」 | **自动**：`rag_report_test` |

## F. soul.md（2.0.6）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| F1 | 生成 | 启动 / 手动 | 七节齐全、≤ 8 KB | **自动**：`rag_soul_test` |
| F2 | 触发 | 7 天后或 +20 篇 | 自动重新生成 | **自动**：`rag_soul_test` |
| F3 | 备份 | 第二次生成 | 保留 `soul.md.bak` | **自动**：`rag_soul_test` |
| F4 | 模型不可用 | 关掉 Ollama | 写统计版，文件存在 | **自动**：`rag_soul_test` |
| F5 | 超长 | 模型输出很长 | 截断到 8 KB 并注明 | **自动**：`rag_soul_test` |

## G. RAG 界面（2.0.7）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| G1 | 导航入口 | 首页 ✦ | 打开 RAG 页，三个页签 | **自动**：`rag_ui_test` |
| G2 | 检索 | 输入问题 → 检索 | 命中列表 | **自动**：`rag_ui_test` |
| G3 | 回原文 | 点日记命中 | 回到主界面并打开那篇 | **自动**：`rag_ui_test` |
| G4 | 日报页 | 切到日报 | 日期列表 + Markdown 预览 | **自动**：`rag_ui_test` |
| G5 | 档案页 | 切到档案 → 重新生成 | 显示 soul 内容 | **自动**：`rag_ui_test` |

## H. 问答与模型设置（2.0.2 / 2.0.3）

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| H1 | 流式回答 | 检索后「生成回答」 | 逐字输出、可停止 | **自动**：`rag_answer_test`、`rag_ui_test` |
| H2 | 引用格式 | 回答内容 | 带 `[日期-标题]` | **自动**：`rag_answer_test` |
| H3 | 真实模型 | qwen3:8b | 应答正确（实测 380 元 / 12345） | **PASS（实测）**：热态 TTFT 0.15 s / 5.4 s |
| H4 | 换交互模型 | 设置里改 | 立即生效（`ollama:qwen3:4b` 等） | **自动**：`rag_answer_test` |
| H5 | 换生成模型 | 设置里改 | 摘要/日报/soul 用新模型 | **自动**：`rag_answer_test` |
| H6 | 设置持久化 | 重启 | `settings.json` 里保留 | **自动**：`rag_answer_test` |
| H7 | 云端开关 | 打开前的确认框 | 说明会发送什么，确认后才开 | 人工 |
| H8 | Key 加密 | 保存 Key 后看 settings.json | 只有 `dpapi:` 密文 | **自动**：`cloud_test` |
| H9 | 云端客户端 | OpenAI 兼容服务 | SSE 流式拼接 + JSON 摘要 | **自动**：`cloud_test`（本地假服务） |
| H10 | 关闭云端 | 关掉开关 | 立即回到本地模型 | 人工 |

## I. 汇总

- 自动化：`flutter analyze` 0 issue、`flutter test` **228 passed**、构建成功、冒烟通过。
- 交付：`dist/MDiary-2.0.0-windows-x64/`、同名 zip、`SHA256SUMS.txt`。
- 待人工确认：B3、G1（真机点击）、H7、H10。
- 已知限制：问答无多轮记忆；embedding 仅本地；模型质量取决于本机模型。
