# 项目目标 Project Goal

## 1. 项目名称
跨平台 .md 日记程序（工作代号：MDiary）

## 2. 背景与目的
 用户可以书写日记，并将日记保存为.md文件。
 解决痛点:跨端同步（Android/iOS/Windows/macOS/Linux）
 价值主张：日记以通用 Markdown 明文保存，不被厂商锁定；离线优先；多端一致体验。

## 3. 核心目标（Must Have，必须完成）
- 目标1：用户书写日记，保存为.md文件。
  - 1.1 支持 Markdown 编辑与"编辑/预览"切换（标题、列表、引用、代码块、表格、链接、图片）。
  - 1.2 自动保存（停止输入 800ms 落库）+ 原子写文件，异常退出不丢稿。
  - 1.3 单篇可"导出为 .md"，也可将整库导出为目录（`<日期>-<标题>.md` + `assets/`）。
- 目标2：文件首先存储到Flutter内置SQLite（在多端验证后采取Go后端服务中PostgreSQL进行数据同步）
  - 2.1 SQLite 为唯一真源（Single Source of Truth），磁盘 .md 为导出物，避免"双真源"。
  - 2.2 表结构：entry / attachment / tag / entry_fts / sync_state，详见第 7 节数据模型。
  - 2.3 schema 版本化迁移（drift），升级不丢数据，迁移前自动备份。
- 目标3：日记文件可查看
  - 3.1 时间轴 / 日历视图列表，按日期分组，支持置顶、软删除与回收站恢复。
  - 3.2 全文检索（中文可用）：标题、正文、标签。
  - 3.3 详情页可切换"预览/编辑"，只读模式亦可导出。
- 目标4：日记可携带附件，增加附件的添加文件格式
  - 4.1 支持格式：图片 png/jpg/jpeg/gif/webp/svg、文档 pdf、文本/代码 txt/md/csv/json，以及其他任意文件（单文件 ≤ 100 MB）。
  - 4.2 交互：拖拽入编辑区、粘贴截图、菜单选择；插入为 `![名称](assets/<sha256>.<ext>)`，点击调用系统默认程序打开。
  - 4.3 存储：附件二进制**存入 SQLite**（`attachment_blobs`，按 sha256 去重，一份字节可被多篇日记索引），
    磁盘 `attachments/<sha256前两位>/<sha256>.<ext>` 仅作预览/打开缓存、可重建；导出一律按原文件形式写回 `assets/`；
    删除条目时按引用计数回收孤儿字节与缓存。

## 4. 迭代目标（Should Have，优先度低）
- 迭代目标1：先在windows端完成程序以及验收（版本号v1.0，预计单人 6–8 周）
  - M0 技术验证（3 天）：Flutter Windows 空壳 + drift + 编辑器 + Markdown 预览 + 附件插入跑通，重点验证中文输入法。
  - M1 数据层（1 周）：schema、迁移、仓储层、导入导出。
  - M2 编辑与预览（2 周）：编辑器、自动保存、附件、快捷键。
  - M3 列表 / 搜索 / 设置（1.5 周）：时间轴、FTS5 检索、主题与字体。
  - M4 打包与验收（1 周）：安装包、崩溃日志、验收清单回归。
- 迭代目标2：先把日记做成 RAG，接入大模型做检索问答与整理（版本号 v2.0）
  - 2.0.1 分块（按标题/段落，带 `entry_id` / 日期 / 标签元数据）→ embedding → 本地向量索引
    （sqlite-vec，与库同目录、可随库备份）；服务端 pgvector 留给 v3.0 复用。
  - 2.0.2 能力：检索问答（带原文引用，可跳回原日记）、自动摘要、标签建议、相似日记推荐。
  - 2.0.3 隐私：默认全本地（Ollama / 本地 embedding）；API Key 只存本机且加密；
    日记内容上送第三方须显式授权、可撤销、可导出。
  - 2.0.4 每日语义管理：每天定时（或启动补跑）对**新增/修改**的日记做切片、摘要、标签建议，
    并**把附件一起索引**（文本类抽文本；图片只索引文件名/类型/大小，不做视觉描述），让检索能命中附件。
  - 2.0.5 日报：小模型每天生成一份当日日报（写了什么 / 关键点 / 待办），带原文引用；
    **日报不进日记列表**，放在新的 RAG 界面里，文件存在 `rag/reports/`。
  - 2.0.6 `soul.md`：把库归纳成一份 ≤ 8 KB 的「灵魂档案」，作为大模型接入时的固定上下文；
    本期不做脱敏（人名地名保持原文），安全策略留到后续迭代。
  - 2.0.7 RAG 独立界面：主界面导航栏新增入口，分「问答 / 日报 / 档案（soul.md）」三块；
    离线启动时自动**补全所有缺失的日报**。
- 迭代目标3：RAG 稳定后再依次移植到 Android/iOS/macOS/Linux，并引入 Go 服务端同步（版本号 v3.0）
  - 移植顺序：Android → macOS → Linux → iOS（iOS 需开发者账号与审核，风险最高放最后）。
  - 移植内容：路径与权限（沙箱 / scoped storage）、分享与导出（share_plus / 文件选择器）、响应式布局与触屏交互。
  - 服务端：Go + PostgreSQL + pgvector，复用 v2.0 的 chunk / embedding，多端增量同步（条目级 LWW）。

## 5. 非目标（Out of Scope，重点！不做什么）
- 不做富文本（Word 式所见即所得）：Markdown 纯文本是唯一存储格式。
- 不在 v1.0 做账号、后端与任何联网功能：纯本地离线可用。
- 不在 v1.0 做端到端加密、密码锁（列入 v1.1 候选：SQLCipher + 应用锁）。
- 不做多人协作、共享日记、评论。
- 不做 Web 端。
- 不做插件系统与主题市场。
- 不做图片编辑、OCR、语音转写。
- 不在 v1.0 支持导出 docx/pdf（最多提供打印预览）。
- 不做 Android/iOS 之外的独立平板设计：平板仅按响应式布局顺带支持。
- 不在同步阶段做自动合并（CRDT）：条目级 LWW + 冲突副本即可。

## 6. 验收标准（Definition of Done）
✅ 目标1、2、3编译成功且通知我测试成功 =项目初步达成
✅ 目标1、2、3、4编译成功且通知我测试成功 =项目整体达成，考虑后续迭代

### 6.1 编译与质量门槛
- `flutter analyze` 0 error、0 warning；`flutter test` 全绿；`flutter build windows --release` 成功产出可执行包。
- 每次提交前 `git diff` 自审并附审查意见（见第 7 节 Git 规范），须含"改动 / 原因 / 风险 / 验证方式 / 回滚方式"。

### 6.2 手工验收清单（v1.0）
- [ ] 新建日记 → 混合输入中英文 → 修改 → 关闭程序重开，内容完整无丢字。
- [ ] 10,000 字长文编辑与滚动无明显卡顿（目标 60 FPS）。
- [ ] 1,000 篇日记下：列表首屏 < 300ms，搜索结果 < 500ms。
- [ ] 分别插入图片、PDF、任意文件各 1 个；重启后可预览 / 打开，附件文件确实存在于工作区。
- [ ] 导出单篇 .md 与整库导出；在 VS Code / Typora 中渲染正确，图片相对路径可显示。
- [ ] 删除日记 → 回收站可恢复；彻底删除后附件被回收。
- [ ] 任务管理器强杀进程后重启，最近一次编辑不丢（WAL + 自动保存生效）。
- [ ] 程序目录不含中文路径、含空格路径下均可正常读写。

## 7. 技术约束
采用Flutter多端客户端（Android/iOS/Windows/macOS/Linux） + Go 后端服务 + PostgreSQL（服务端主库） + SQLite（客户端本地离线库）
使用本地Git作为版本管理，每次提交必须diff并提交审查意见

### 7.1 客户端选型（M0 验证后定稿）
计划：Flutter stable（3.x）+ Dart 3；Riverpod；go_router；drift（SQLite + FTS5）；flutter_markdown 系渲染器。

**v1.0 实际落地**（与计划的偏差已登记在 `docs/architecture.md` §5）：
- 状态管理用内置 `ChangeNotifier` + `InheritedNotifier`（单窗口够用，少一层依赖）；
- 路由用 `Navigator`（页面只有设置 / 回收站 / 星图）；
- 数据层用 `sqlite3` 手写 SQL + `PRAGMA user_version` 迁移（不引 drift / build_runner，首编失败面更小）；
- 检索用 `LIKE` 子串（标题/正文/标签），千篇实测 < 50ms，FTS5 留到量级变大再上；
- 附件：file_picker 选择 + Windows 原生拖拽（`WM_DROPFILES`）+ 剪贴板截图（GDI+ 编码 PNG），内容寻址存储。

### 7.2 数据模型（客户端 SQLite）
- `entry(id TEXT PK uuidv7, title TEXT, body_md TEXT, entry_date DATE, created_at, updated_at, rev INTEGER, deleted_at, device_id)`
- `attachment(id, entry_id, sha256, filename, mime, size, created_at)`
- `attachment_blobs(sha256 PK, size, bytes)`：附件字节（schema v2 起入库，按 sha 去重）
- `tag(id, name)` / `entry_tag(entry_id, tag_id, PRIMARY KEY(entry_id, tag_id))`
- `entry_fts`（FTS5 虚表，trigram 分词，rowid ↔ entry.id 映射）
- `sync_state(key, value)`：last_sync_cursor、last_export_at 等
- **v2.0（RAG）独立库**：RAG 产物不写进日记库，统一放 `<库目录>/rag/`：
  - `rag/index.sqlite`：`chunk(id, entry_id, attachment_id, kind, ordinal, text, summary, hash, updated_at)`、
    `chunk_vec`（sqlite-vec 虚拟表，rowid ↔ chunk）、
    `entry_summary(entry_id PK, summary, tags_suggested, generated_at, model)`、
    `attachment_text(sha256 PK, text, source)`、`report(date PK, markdown, model, generated_at)`、
    `index_meta(key, value)`、`job(id, kind, target_date, status, attempts, last_error)`；
  - `rag/reports/YYYY-MM-DD.md`：日报的可读副本（与 `report` 表同源）；
  - `rag/soul.md`：灵魂档案（+ `soul.md.bak`）。
  索引可由日记重建；`reports/` 与 `soul.md` 是生成物，备份时随库一起复制。

### 7.3 目录与仓库结构
- monorepo：`apps/client_flutter/`、`services/go_api/`（v3.0 起）、`docs/`（含 `docs/reviews/`）、`scripts/`、`infra/`（v3.0 起）。
- 数据目录：默认 `<exe 目录>/MDiaryData/`，绿色版随 exe 走；结构为
  `db/mdiary.sqlite`（数据库，含附件字节）+ `attachments/`（预览/打开缓存，可重建）+ `logs/`。
  老版本放在根目录的 `mdiary.sqlite` 会在启动时自动搬进 `db/`。
  设置页可换目录并迁移，指针存在 `<exe 目录>/mdiary-location.txt`；`MDIARY_HOME` 可覆盖；目录不可写时逐级回退。
- 多库：一个目录 = 一个库（`<目录>/mdiary.sqlite`）。设置 → 数据 可「切换 / 新建库」、
  「导入新库」（复制到 `MDiaryData/libraries/<名字>/` 并切换）、「合并库」（按 id 合并，
  同 id 保留 updated_at 较新的，附件按 sha256 去重，标签按名字合并）。当前库与最近库记在
  `MDiaryData/libraries.json`；默认库仍是 `MDiaryData/db`。

### 7.4 Git 与审查规范
- 分支：`main` 受保护；特性分支 `feat/xxx`、`fix/xxx`；提交信息走 Conventional Commits。
- 每次提交必须先 `git add -p` / `git diff --staged` 自审，审查意见写入提交正文（模板：改动 / 原因 / 风险 / 验证方式 / 回滚），必要时在 `docs/reviews/YYYYMMDD-<topic>.md` 存档。
- 提交模板放 `.gitmessage`，`git config commit.template .gitmessage` 生效。

### 7.5 后端与同步（v3.0，本期仅预留字段）
- Go 1.22+：路由 chi/fiber、驱动 pgx、查询 sqlc（或 GORM）；契约先行（OpenAPI）。
- 表：users / devices / entries（与客户端同构 + owner_id + rev）/ attachments（按 sha256 去重）/ entry_commits（审计）。
- 同步协议：`GET /sync?since=<rev>` 拉增量，`POST /sync` 推变更，条目级 LWW；冲突落盘为 `标题 (冲突副本 2026-11-02).md`。
- 认证：邮箱/设备码 + JWT；附件走 S3/MinIO 预签名直传。
- 检索：PostgreSQL 中文分词（zhparser/pg_jieba）或 pgvector（复用 v2.0 的 RAG chunk/embedding）。

### 7.6 RAG 技术选型（v2.0）

**目标**：日记只在本机就能「问一句、答一段、带出处」，不强制联网；联网能力是可选增强。

**三种部署形态**（推荐 A，按需升级到 C）：

| 形态 | 组成 | 优点 | 代价 |
|---|---|---|---|
| **A. 纯本地（推荐）** | `sqlite-vec` + 本地 embedding（Ollama `bge-m3` 或 ONNX `fastembed`）+ 可选本地 LLM（Ollama `qwen3` / `llama3.1`） | 全离线、无服务进程、索引与库同目录（可随库备份）、绿色版友好 | 首次要下模型；小模型效果有上限 |
| B. 桌面一体化 | 参考 AnythingLLM Desktop（Electron + LanceDB） | 开箱即用的文档问答 | 和 Flutter 集成成本高、体积大 |
| C. 自托管服务 | RAGFlow / Dify（Docker） | 解析 / 切片 / rerank / 引用成熟，多设备共享 | 要 Docker 或服务器，不适合塞进 exe |

**开源候选**（许可与特性以各自仓库为准）：

| 类别 | 候选 | 说明 |
|---|---|---|
| 嵌入式向量检索 | [sqlite-vec](https://github.com/asg017/sqlite-vec)、[LanceDB](https://github.com/lancedb/lancedb) | 前者是单文件 SQLite 扩展，暴力 KNN，十万级 chunk 够用；后者列式存储、带磁盘索引 |
| 向量服务 | [Chroma](https://github.com/chroma-core/chroma)、[Qdrant](https://github.com/qdrant/qdrant)、[pgvector](https://github.com/pgvector/pgvector) | 前两个可本机跑；pgvector 留给 v3.0 服务端 |
| RAG 平台 | [RAGFlow](https://github.com/infiniflow/ragflow)（Apache-2.0）、[Dify](https://github.com/langgenius/dify)、[AnythingLLM](https://github.com/Mintplex-Labs/anything-llm)（MIT）、[Khoj](https://github.com/khoj-ai/khoj)（AGPL-3.0） | RAGFlow 强在深度文档解析；AnythingLLM 有桌面版可参考；Khoj 是 AGPL，商用/闭源分发要谨慎 |
| 图谱增强 | [LightRAG](https://github.com/HKUDS/LightRAG)（MIT） | 实体关系 + 向量，适合"人物/地点/事件"式回忆，可作为 v2.x 增强 |
| 框架 | [LlamaIndex](https://github.com/run-llama/llama_index)、[Haystack](https://github.com/deepset-ai/haystack) | 想自己拼流水线时用；纯 Dart 生态目前没有成熟替代 |
| 中文 embedding / rerank | BGE-M3、bge-reranker-v2-m3、Qwen3-Embedding | 开源权重，可本地跑；中文日记建议先用 BGE-M3 |
| 推理运行时 | [Ollama](https://github.com/ollama/ollama)、[llama.cpp](https://github.com/ggml-org/llama.cpp) | Ollama 最省事；要嵌进安装包时用 llama.cpp |

**v2.0 落地路线**：

1. **切片**：Markdown 结构感知（标题树 + 段落，代码块整块保留），512–800 tokens，
   每个 chunk 带 `entry_id` / `entry_date` / `tags`。
2. **索引**：`chunk` 表 + `sqlite-vec` 虚拟表（BGE-M3 = 1024 维）；同时用 FTS5/trigram 做关键词召回，
   两路结果 RRF 融合，可选本地 rerank。
3. **生成**：默认本地 Ollama；用户也可填自己的 API Key（只存本机、加密）。
   回答必须带 `[日期-标题]` 引用，点引用跳回原日记。
4. **增量**：保存/删除日记时只重算该条目的 chunk；启动做一次补偿扫描；索引文件放库目录下随库备份。
5. **隐私**：默认不出网；切到云端 embedding/LLM 时二次确认；日志不记录正文。
6. **评测**：用 30–50 条真实日记做问答集，量 recall@5 与引用准确率，再决定换更大模型或加 rerank。

### 7.7 语义管理 / 日报 / soul.md / RAG 界面（v2.0）

> **2.0.1 已完成**：`lib/rag/`（切片 / embedding / 索引 / 混合检索）+ `tool/rag_search.dart` 命令行，
> 细节见 `docs/rag.md`。

RAG 的产物统一放 `<库目录>/rag/`：索引可重建；`reports/` 与 `soul.md` 是生成物，跟着库走。
**日报不进日记列表**，只在 RAG 界面里看。

**RAG 独立界面（2.0.7）**
- 主界面导航栏新增入口（与「星图」「回收站」「设置」并列），页面三块：
  - **问答**：输入问题 → 混合检索 + 小模型回答；答案带 `[日期-标题]` 引用，点引用跳回日记或附件；
  - **日报**：左侧按月份分组的日报列表（只列有日记的日期），右侧看当天日报；顶部有「补全缺失」「重新生成今天」；
  - **档案**：渲染 `rag/soul.md`，可复制全文 / 重新生成。
- 首次启动时后台补全日报（显示进度，可暂停/取消），不阻塞主界面。

**调度（桌面程序不是常驻服务）**
- 启动时查 `job`：`last_daily_run < 今天` 就补跑；全部本地，离线不影响。
- 日报按「天」补全：从最后一份日报的次日补到昨天；没有日记的日期直接跳过（不产生空日报）。
- 同一 `target_date` 幂等、可断点续跑；单条失败记 `last_error`（重试 3 次退避），不阻塞其它天。

**每日流水线**（只处理 `updated_at > last_indexed_at` 的条目与新附件）
1. 切片：Markdown 结构感知（标题树 + 段落，代码块整块保留），512–800 tokens，带 `entry_id` / 日期 / 标签。
2. **附件索引**：所有附件写一条 `chunk(kind='attachment')`（文件名 + 类型 + 大小 + 所属日记摘要），
   保证检索能命中「那张发票截图」；文本类（txt/md/csv/json/代码）抽全文再切块；
   PDF 只抽可选中文本，失败就只留元数据；**图片不调用视觉模型**，只有元数据 + 可选人工备注。
3. 摘要：小模型给每个 chunk 写 1–2 句摘要，再汇总成 `entry_summary`；标签建议只展示，不自动改用户标签。
4. embedding：批量（如 32 条/批）调本地 BGE-M3 写 `chunk_vec`；模型/维度变更时整库重建。
5. 日报 + soul.md（见下）。
6. 收尾：`last_indexed_at = now`，写 `job` 记录。

**日报（`rag/reports/YYYY-MM-DD.md` + `report` 表，不进 entries）**
- 输入：当天新增/修改条目的摘要 + 当天附件名；输出三段：`今天写了什么`（时间线）、`关键点 / 待办`、`一句话总结`；
- 每条要点带 `[日期-标题]` 引用；当天没有日记则不生成。
- 存储：文件 + `report(date, markdown, model, generated_at)` 表；不写 entries，不出现在日记列表与 .md 导出里
  （整库导出可选附带 `rag/reports/`）。
- 补全：离线打开时逐日补齐缺失日报，界面显示「已补全 N 天 / 剩余 M 天」。

**soul.md（`rag/soul.md`）**
- 定位：给大模型的「这个人和这个库」的固定上下文，不是全量导出；预算 **≤ 8 KB**（约 3–4k tokens）。
- 固定骨架：`## 1. 这个人` / `## 2. 长期主题` / `## 3. 重要的人·地点·项目` / `## 4. 写作与语气` /
  `## 5. 时间线（每年一行）` / `## 6. 近期状态（最近 30 天）` / `## 7. 如何检索这个库（标签词表、附件约定、日报位置）`。
- 两阶段生成：(a) 年/月滚动摘要（缓存、增量更新）；(b) 用滚动摘要 + 近期摘要合成，避免每次全库喂模型。
- 触发：距上次 ≥ 7 天、或新增 ≥ 20 篇、或手动「重新生成」；写 `.tmp` 后 rename，保留 `soul.md.bak`。
- 本期不做脱敏：人名/地名保持原文，安全策略（脱敏、口令、加密）留到后续迭代。

**备份**
- 「备份数据库」在 `VACUUM INTO` 之后，顺手把 `rag/reports/` 与 `rag/soul.md` 复制进同一份备份目录（都是小文本）；
  `rag/index.sqlite` 不备份（可由日记重建）。

**给 agent 的工具面（与 §7.6 的 MCP 一致）**
`search_diary` / `get_entry` / `get_attachment` / `get_soul` / `get_daily_report(date)` / `list_tags` / `ask_diary`。

## 8. 风险与假设## 8. 风险与假设
### 8.1 假设条件（依赖什么）
- A1 单人开发，v1.0 仅交付 Windows；其余平台在 v3.0 排期（v2.0 先做 RAG）。
- A2 用户接受"SQLite 为真源、磁盘 .md 为导出物"，不要求直接编辑磁盘文件再回写数据库（镜像/双向模式列为 v1.1 可选）。
- A3 附件二进制存 SQLite（`attachment_blobs`，schema v2 起）；磁盘 `attachments/` 只作预览/打开缓存，可随时重建。
- A4 规模假设：单篇正文 ≤ 100 KB，附件单文件 ≤ 100 MB，单库总量 ≤ 2 GB。
- A5 目标环境：Windows 10 1809+ / x64，UTF-8 无 BOM、LF 换行。
- A6 界面以中文为主，v1.0 不做 i18n，但文案集中管理便于后续抽取。

### 8.2 已知风险与对策
- R1【高】Flutter Windows 上中文 IME 的组词与光标异常 → M0 优先验证；编辑器实现隔离，保留替换方案。
- R2【高】"双真源"（SQLite 与磁盘 .md 同时可写）导致数据不一致 → 单一写入路径：磁盘侧只读导入 + 覆盖式导出。
- R3【中】Markdown 方言差异（表格/脚注/数学公式） → 明确只支持 CommonMark + GFM 子集，文档写明；渲染与源码冲突时以源码为准。
- R4【中】FTS5 默认分词对中文无效 → 采用 trigram 分词或自带词表，先用真实语料度量效果。
- R5【中】附件体积失控与孤儿文件 → 引用计数 + 定期 GC + 单文件大小上限 + 导出时校验完整性。
- R6【中】跨端字体与换行差异 → 统一 LF、UTF-8、相对路径，导出前做规范化。
- R7【低】Windows 未签名安装包被 SmartScreen 拦截 → 先发未签名 zip + 安装说明，后续考虑代码签名。
- R8【低】同步与 RAG 阶段的隐私合规 → 默认本地；上送第三方须显式授权、可撤销、可导出全部数据。
- R9【低】范围蔓延（主题、插件、AI 功能提前进入） → 以第 5 节非目标为准，新需求一律进 v1.1 backlog。

## 9. 交付物清单
- 代码库（monorepo：Flutter 客户端 + Go 服务端 + docs + scripts）
- v1.0 Windows 安装包（`MDiary-1.0.0-windows-x64.zip`）与 `README.md`（安装 / 使用 / 备份说明）
- 数据库 schema 迁移文件与说明（`docs/schema.md`）
- 验收入口清单与测试记录（`docs/acceptance-v1.1.md`）
- 提交审查记录（`docs/reviews/` + `.gitmessage` 模板）
- 示例 Vault（3 篇日记 + 附件），用于导入导出回归验证
- （v2.0）RAG 独立界面（问答 / 日报 / 档案）、本地索引与语义管理、日报、`soul.md`、检索接口文档
- （v3.0）Android APK / iOS TestFlight / macOS dmg / Linux AppImage（+ 同步服务端）

## 10. 交付状态（v1.0 2026-11-03 / v1.1 2026-11-05 / v1.1.1 打磨）

### 10.1 已达成（对应第 3 节 Must Have）

| 目标 | 状态 | 说明 |
|---|---|---|
| 1.1 编辑 / 预览 | ✅ | GFM 子集（标题/列表/引用/代码块/表格/链接/图片），编辑 / 分栏 / 预览三态 |
| 1.2 自动保存 + 原子写 | ✅ | 800ms 防抖 + Ctrl+S / 失焦 / 关窗强制落库；导出先写 `.tmp` 再改名 |
| 1.3 导出 | ✅ | 单篇与整库（`<日期>-<标题>.md` + `assets/`），front matter 含 tags |
| 2.1 单一真源 | ✅ | SQLite 是唯一写入路径，磁盘 `.md` 只用于导出 / 导入 |
| 2.2 表结构 | ✅（两处偏差） | entry / attachment / tag / entry_tags / app_meta 齐；`entry_fts` 未建（用 LIKE）、`sync_state` 由 app_meta 顶替 |
| 2.3 迁移与备份 | ✅ | `PRAGMA user_version` 迁移；升级前 `VACUUM INTO` 自动快照 |
| 3.1 视图 | ✅ | 时间轴 + 左栏月历（点日期新建 / 打开当天）、置顶、软删除、回收站 |
| 3.2 检索 | ✅ | 标题 + 正文 + 标签，中文子串匹配 |
| 3.3 预览态 | ✅ | 预览 / 分栏下可直接导出 |
| 4.1 附件格式 | ✅ | 任意文件 ≤ 100 MB，图片内嵌预览 |
| 4.2 插入方式 | ✅ | 菜单选择、Windows 拖拽、剪贴板截图（工具栏按钮 / Ctrl+Shift+V） |
| 4.3 存储 | ✅ | sha256 内容寻址、**字节入库（attachment_blobs）**、磁盘仅缓存、彻底删除后自动 GC |

附加能力（超出 v1.0 计划，已并入本版）：左栏月历、星图（全部/年/月/周，共用附件连线）、
标签（列表/搜索/导出导入）、绿色版数据目录与迁移、附件名写进 .md 且预览里彩色可点。

> v1.0 交付后按新需求调整：附件由「只存文件系统」改为「字节入库 + 磁盘缓存」，单文件上限
> 25 MB → 100 MB（schema v2，启动时自动把老文件回填进库）。这项改动在 v1.0 标签之后开发，
> 计入 v1.1 版本线；v1.0.0 的安装包保持原样。

### 10.2 质量门槛

- `flutter analyze` 0 issue；`flutter test` 187 passed（v1.1.1）；`flutter build windows --release` 成功。
- 交付物：`dist/MDiary-1.0.0-windows-x64/` 与同名 zip（含 README / 使用说明 / 交付说明 / 发布说明 / 验收清单）。

### 10.3 已知遗留（v1.1 候选，详见 `docs/backlog-v1.1.md`）

- 单实例互斥、回收站「清空」、窗口尺寸记忆、最小窗口限制；
- 打开附件走 `cmd /c start`（用户名含 `&` / `%` 时有风险）；
- 导出附件名是哈希（可读性）；
- 检索未上 FTS5（单库 > 5,000 篇再评估）；
- 截图粘贴仅 Windows（依赖 runner 方法通道，其它平台需要各自的实现）。

### 10.4 后续开发起点

- **v1.1（打磨）**：先做 backlog A 组（单实例、`ShellExecuteW`、导出幽灵条目、导入大小上限）+ B 组体验项。
- **v2.0（RAG，本地优先）**：按 §7.6 的路线做切片 + 本地 embedding + sqlite-vec；再看 §7.7 的
  RAG 独立界面、每日语义管理（含附件索引）、日报（不进日记）、`soul.md`；问答必须带引用，
  API Key 只存本机；服务端化留给 v3.0。
- **v3.0（多端 + 同步）**：`services/go_api/` 按 §7.5 起步，pgvector 复用 v2.0 的索引；客户端把写入
  改为「本地库 + 同步队列」双写，`rev` / `device_id` / `deleted_at` 已预留。
- 开发命令：`scripts/verify.ps1`（analyze + test + build）、`scripts/build.ps1`（含 `--no-tree-shake-icons`）。
