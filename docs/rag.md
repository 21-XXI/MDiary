# RAG 索引（v2.0 / 2.0.1）

> 状态：**2.0.1 / 2.0.4 / 2.0.5 已完成**——切片、附件索引、增量重建、混合检索、命令行，
> 每日语义管理（摘要 + 标签建议），以及日报（`rag/reports/`）；界面留给 2.0.7。

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
| `tool/rag_report.dart` | 日报命令行 |

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

## 11. 已知限制（2.0.1 / 2.0.4 / 2.0.5）

- 向量检索是暴力扫描，单库 > 5 万切片会变慢；
- PDF / 图片只索引元数据，不抽正文；
- 还没有 RAG 界面与 soul.md（后续 2.0.6–2.0.7）；摘要目前只有条目级，chunk 级摘要未做；
- 索引不参与「备份数据库」，但可以随时重建。
