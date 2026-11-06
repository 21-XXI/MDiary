# RAG 索引（v2.0 / 2.0.1）

> 状态：**v2.0 已完成**——索引与混合检索、每日语义管理（摘要 + 标签建议）、日报、灵魂档案、
> RAG 独立界面、流式问答（带引用），以及可配置的交互/生成模型。

## 1. 产物位置

```
<库目录>/
  db/mdiary.sqlite        # 日记库（不变）
  rag/
    index.sqlite          # 切片 + 向量 + 增量记录（可随时删掉重建）
    reports/              # 日报（2.0.5，暂未生成）
    soul.md               # 灵魂档案（2.0.6，暂未生成）
```

索引与日记库分开：删 `rag/index.sqlite` 不影响日记，重跑一次索引就能恢复。

## 2. 索引库结构（`rag/index.sqlite`，schema v1）

| 表 | 用途 |
|---|---|
| `chunk` | 切片：`kind`(entry/attachment)、`entry_id`、`attachment_id`、`ordinal`、`heading_path`、`label`、`source_date`、`text`、`tokens`、`hash` |
| `chunk_vec` | 向量：`chunk_id`、`dim`、`vector`（float32 BLOB，已 L2 归一化） |
| `entry_index` | 条目增量指纹：`source_hash` + 切片数 |
| `attachment_index` | 附件增量指纹 |
| `attachment_text` | 从文本类附件抽出的正文（≤ 200 KB） |
| `entry_summary` / `report` / `job` / `index_meta` | 2.0.4–2.0.6 预留，2.0.1 只用 `index_meta` |

`index_meta` 目前记录：`embed_model`、`embed_dim`、`indexed_at`。

## 3. 切片规则

- Markdown 结构感知：`#` 标题开新节，切片带 `章节：H1 > H2`；
- 每个切片前缀 `《标题》日期 · 标签：…`，让标题/日期/标签也能被检索；
- 代码块（``` / ~~~）整块保留，不按空行切；
- 目标 560 tokens、上限 800；超长段落按行再切；
- 附件单独成片：`附件：文件名` + 类型/大小 + 所属日记；文本类附件（txt/md/csv/json/代码等）
  再抽正文一起索引；PDF 暂时只索引元数据（后续接文本抽取）。

token 估算：中日韩字符按 1 个、其它字符按 4 个算 1 个（不做真正分词）。

## 4. 增量与模型切换

- 条目指纹 = `title + body + date + tags`；附件指纹 = `文件名 + mime + 大小 + 抽出的文本`；
- 指纹没变就跳过，不会重复 embedding；
- `index_meta.embed_model` 变化（或维度对不上）→ 自动清空切片并整库重建。

## 5. 检索

混合检索 + RRF 融合（`k=60`）：

1. **向量**：查询先 embedding，再和所有切片算余弦（当前是纯 Dart 暴力 KNN，
   几万条以内够用；数据量再大再换 sqlite-vec 之类的索引）；
2. **关键词**：查询在切片正文里的出现次数，标题命中 ×3、章节命中 ×2；
3. 两路排名按 `1/(60+rank)` 相加，取前 k 条。

返回：`kind`（日记/附件）、`label`、日期、片段、`entryId`/`attachmentId`、分数。

## 6. 本地模型

默认走本地 Ollama：

```bash
ollama pull bge-m3
```

- 地址默认 `http://127.0.0.1:11434`，模型默认 `bge-m3`（1024 维）；
- 连不上 / 没拉模型时抛 `EmbedderUnavailable`，界面会提示安装，不会影响日记功能；
- `HashingEmbedder` 只是离线自检用（无模型、确定性），**语义质量很差**，不要用于真实使用。

## 7. 命令行（2.0.1 验收入口）

```bash
# 建/更新索引（增量）
dart run tool/rag_search.dart --root <库目录> --reindex

# 没有 Ollama 时自检链路
dart run tool/rag_search.dart --root <库目录> --reindex --fake-embedder

# 检索
dart run tool/rag_search.dart --root <库目录> "去年在杭州"
dart run tool/rag_search.dart --root <库目录> "发票" --json --k 5
```

- `--root` 可以是库目录（含 `mdiary.sqlite`）或数据目录（含 `db/mdiary.sqlite`）；
- Windows 下需要能加载 `sqlite3.dll`：默认找 `build/windows/x64/runner/Release/sqlite3.dll`，
  也可用环境变量 `MDIARY_SQLITE_DLL` 指定；
- 退出码：`0` 成功，`1` 参数/数据错误，`2` 本地模型不可用。

## 8. 代码结构

| 文件 | 说明 |
|---|---|
| `lib/rag/chunker.dart` | Markdown 切片、附件切片、token 估算 |
| `lib/rag/embedder.dart` | `Embedder` 接口、`OllamaEmbedder`、`HashingEmbedder` |
| `lib/rag/rag_database.dart` | `rag/index.sqlite` 建表与读写 |
| `lib/rag/semantic_indexer.dart` | 增量索引（日记 + 附件） |
| `lib/rag/rag_service.dart` | 对外的索引/检索入口 |
| `lib/rag/attachment_text.dart` | 文本类附件抽取 |
| `lib/rag/summarizer.dart` | 摘要生成：`OllamaSummarizer`（/api/chat，JSON）+ `FakeSummarizer` |
| `lib/rag/daily_job.dart` | 每日语义管理：增量摘要、job 表、`last_daily_run` |
| `lib/rag/content_hash.dart` | 条目/附件内容指纹（索引与摘要共用） |
| `tool/rag_search.dart` | 索引/检索命令行 |
| `lib/rag/report_job.dart` | 日报：空日文案、离线骨架、模型润色、补全窗口 |
| `tool/rag_daily.dart` | 每日语义管理命令行 |
| `lib/rag/soul_job.dart` | 灵魂档案：统计汇总、模型概括、8 KB 预算、版本备份 |
| `tool/rag_report.dart` | 日报命令行 |
| `tool/rag_soul.dart` | 灵魂档案命令行 |
| `lib/rag/answer.dart` | 流式问答（Ollama `/api/chat`，关闭 thinking） |
| `lib/rag/rag_settings.dart` | 交互/生成/向量模型设置（settings.json） |
| `lib/features/rag_page.dart` | RAG 界面（问答 / 日报 / 档案） |
| `scripts/bench-ollama.ps1` | 本地模型性能测量 |

## 9. 每日语义管理（2.0.4）

`DailySemanticJob`：每天第一次启动时，对「新增 / 修改过」的日记生成**摘要 + 标签建议**。

- **触发**：应用启动 5 秒后后台执行（`main.dart`）；今天跑过就跳过；`--force` 可强制重跑。
- **幂等**：每篇的指纹 = 标题 + 正文 + 日期 + 标签；没变就不调模型。
- **存储**：`entry_summary(entry_id, summary, tags_suggested, generated_at, model, source_hash)`；
  `tags_suggested` 只建议，**不会自动改用户标签**。
- **任务记录**：`job(id='daily:YYYY-MM-DD', status=running/done/partial/failed, attempts, last_error)`；
  成功后写 `index_meta.last_daily_run`。
- **失败语义**：模型不可用 → 整次任务 `failed`，**不写** `last_daily_run`，下次启动重试；
  单篇失败（如解析异常）→ `partial`，其它篇继续。
- **模型**：默认 `qwen3:8b`（Ollama `/api/chat`，`format: json`），可用 `--model` 换小模型。

命令行：

```bash
# 增量索引 + 摘要（需要 Ollama + qwen3:8b）
dart run tool/rag_daily.dart --root <库目录>

# 不联网自检
dart run tool/rag_daily.dart --root <库目录> --fake --verbose

# 强制重跑今天
dart run tool/rag_daily.dart --root <库目录> --force
```

退出码：`0` 成功/跳过，`1` 参数/数据错误，`2` 本地模型不可用，`3` 有单篇失败（partial）。

## 10. 日报（2.0.5）

每天一篇：`rag/reports/YYYY-MM-DD.md` + `report(date, markdown, model, generated_at)` 表。

- **空日也写**：没有日记的日期生成「这一天没有写日记，也没有新增附件」，
  连续多天没有记录时追加「已经连续 N 天没有记录」。
- **有内容的日子**：先拼**离线骨架**（标题、摘要或正文首行、附件名），
  模型可用时再润色成三段式：`## 今天写了什么` / `## 关键点 / 待办` / `## 一句话总结`，
  每条带 `[日期-标题]` 引用；模型不可用就保留骨架并在开头注明。
- **补全范围**：启动后补齐 `[最早日记, 昨天]`，默认最多回看 **366 天**；
  最近 **30 天**调用模型润色，更早的只写骨架（省算力）。
- **今天不自动生成**：避免写出"半截日报"；需要时用 `--date 今天` 手动生成。
- 写文件是 `.tmp` → rename 原子替换；已有日报默认跳过，`--force` 覆盖。

```bash
# 补齐到昨天（空日也写）
dart run tool/rag_report.dart --root <库目录>

# 只生成某一天 / 强制重写
dart run tool/rag_report.dart --root <库目录> --date 2026-11-05
dart run tool/rag_report.dart --root <库目录> --date 2026-11-05 --force

# 不连模型，只写离线骨架
dart run tool/rag_report.dart --root <库目录> --no-model
```

## 11. 灵魂档案 soul.md（2.0.6）

`<库目录>/rag/soul.md`：给大模型的「这个人 / 这个库」固定上下文，**≤ 8 KB**。

- 固定七节：`1. 这个人` / `2. 长期主题` / `3. 重要的人·地点·项目` / `4. 写作与语气` /
  `5. 时间线（每年一行）` / `6. 近期状态（最近 30 天）` / `7. 如何检索这个库`；
- 1–4、6 由模型概括（输入是统计 + 最近摘要样本，不喂全库）；5 与 7 由程序按统计生成；
- 模型不可用 → 写「统计版」，文件照样存在；
- 触发生成：文件不存在、距上次 ≥ 7 天、或新增 ≥ 20 篇；也可手动 `--force`；
- 写文件前保留上一版 `soul.md.bak`；超过 8 KB 按行截断并注明；
- 不做脱敏（人名地名保持原文），安全策略留到后续迭代。

```bash
dart run tool/rag_soul.dart --root <库目录>          # 到期才重生成
dart run tool/rag_soul.dart --root <库目录> --force   # 强制重写
dart run tool/rag_soul.dart --root <库目录> --show    # 只看现有内容
```

`get_soul`（MCP 工具）直接返回这个文件；也可以把它贴进任意大模型的 system prompt。

## 12. 本地模型测量（bench-ollama.ps1）

`scripts/bench-ollama.ps1` 会：探测 Ollama → 按需拉模型 → 预热（记录加载耗时）→
跑 3 组中文任务的推理基准（tok/s、总耗时、输出 token）→ 测流式首 token（TTFT）→
测 `bge-m3` embedding 吞吐，最后把结果写到 `bench-ollama.json`。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1
powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1 -Model qwen3:4b -Runs 5
powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1 -SkipEmbed
```

前提：`ollama` 已安装且在运行（脚本会在服务未起时尝试 `ollama serve`；找不到 `ollama`
时可用环境变量 `OLLAMA_BIN` 指定）。模型默认 `qwen3:8b`（约 5.2 GB）与 `bge-m3`（约 1.2 GB），首次会下载。

**这台机器的实测结果**见 [`docs/bench-ollama.md`](bench-ollama.md)：
qwen3:8b 约 10.5 tok/s、TTFT 0.8 s，30% CPU / 70% GPU 混合推理；bge-m3 100% GPU，
300 字切片约 5.5 条/秒。

## 13. RAG 界面（2.0.7）

主界面导航栏新增 ✦ 图标（与星图 / 回收站 / 设置并列），点开是独立页面，三个页签：

- **问答**：输入问题 →「检索」→ 命中列表（日记/附件、日期、片段、分数）。
  点日记命中会回到主界面并打开那篇；点附件命中用系统默认程序打开。
  目前只有检索，**生成式回答在 2.0.2 接入**；
- **日报**：左侧日期列表、右侧 Markdown 预览；顶部「补全缺失」（补到昨天，空日也写）、
  「重新生成今天」（当天可反复重写）；
- **档案**：渲染 `rag/soul.md`，可「重新生成」「复制全文」。
- 右上角菜单：「重建索引」「打开库目录」。

日报与档案的 Markdown 都套在滚动容器里，长内容不会溢出；
档案生成/日报补全期间按钮禁用并提示结果。

## 14. 问答生成（2.0.2）

问答页的「生成回答」把检索到的前几条片段拼成上下文，交给**交互模型**流式作答：

- 提示词要求 **只根据片段回答**、每条事实用 `[日期-标题]` 标注来源，没有依据就说「日记里没有提到」；
- 逐字流式显示，可随时「停止」；回答下方保留命中列表，点开可回原文；
- 默认 `think: false`：qwen3 这类思考模型在问答场景会先想很久，
  实测 **27.5 s 且答错**（把有依据的问题答成「没有提到」），关掉后 **9 s 答对**；
- 热态实测（qwen3:8b，2 条片段）：**TTFT 0.15 s，整段 5.4 s**；冷启动（含加载）11 s / 15.5 s。

### 模型设置（设置 → RAG 模型）

| 项 | 作用 | 默认 |
|---|---|---|
| 交互模型 | 问答（`/api/chat` 流式） | `qwen3:8b` |
| 生成模型 | 摘要 / 日报 / soul.md | `qwen3:8b` |
| 向量模型 | 切片 embedding | `bge-m3` |
| Ollama 地址 | 本机服务地址 | `http://127.0.0.1:11434` |

- 存在 `<数据目录>/settings.json`，**全局生效**（不随库切换）；
- 设置页会「检测本机模型」给出下拉项，改完立即生效；
- 向量模型或地址变了会关掉旧索引连接，下次检索自动重建。

## 15. 已知限制（v2.0）

- 向量检索是暴力扫描，单库 > 5 万切片会变慢；
- PDF / 图片只索引元数据，不抽正文；
- 摘要目前只有条目级，chunk 级摘要未做；问答没有多轮记忆（每次独立）；
- 索引不参与「备份数据库」，但可以随时重建。
