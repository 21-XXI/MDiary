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
- 迭代目标2：后依次移植到Android/iOS/macOS/Linux（版本号v2.0）
  - 移植顺序：Android → macOS → Linux → iOS（iOS 需开发者账号与审核，风险最高放最后）。
  - 移植内容：路径与权限（沙箱 / scoped storage）、分享与导出（share_plus / 文件选择器）、响应式布局与触屏交互。
- 迭代目标3：可将文件制作成rag，接入大模型api进行管理（版本号v3.0）
  - 3.0.1 分块（按标题/段落，带 entry_id 元数据）→ embedding → pgvector 入库。
  - 3.0.2 检索问答、自动摘要、标签建议、相似日记推荐。
  - 3.0.3 API Key 仅存服务端；支持本地模型选项；日记内容上送第三方须显式授权且可撤销。

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
- `attachment_blobs(sha256 PK, size, bytes)`：附件字节（v2 起入库，按 sha 去重）
- `tag(id, name)` / `entry_tag(entry_id, tag_id, PRIMARY KEY(entry_id, tag_id))`
- `entry_fts`（FTS5 虚表，trigram 分词，rowid ↔ entry.id 映射）
- `sync_state(key, value)`：last_sync_cursor、last_export_at 等

### 7.3 目录与仓库结构
- monorepo：`apps/client_flutter/`、`services/go_api/`（v2.0 起）、`docs/`（含 `docs/reviews/`）、`scripts/`、`infra/`（v2.0 起）。
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

### 7.5 后端与同步（v2+，本期仅预留字段）
- Go 1.22+：路由 chi/fiber、驱动 pgx、查询 sqlc（或 GORM）；契约先行（OpenAPI）。
- 表：users / devices / entries（与客户端同构 + owner_id + rev）/ attachments（按 sha256 去重）/ entry_commits（审计）。
- 同步协议：`GET /sync?since=<rev>` 拉增量，`POST /sync` 推变更，条目级 LWW；冲突落盘为 `标题 (冲突副本 2026-11-02).md`。
- 认证：邮箱/设备码 + JWT；附件走 S3/MinIO 预签名直传。
- 检索：PostgreSQL 中文分词（zhparser/pg_jieba）或 pgvector（v3 复用）。

## 8. 风险与假设
### 8.1 假设条件（依赖什么）
- A1 单人开发，v1.0 仅交付 Windows；其余平台在 v2.0 排期。
- A2 用户接受"SQLite 为真源、磁盘 .md 为导出物"，不要求直接编辑磁盘文件再回写数据库（镜像/双向模式列为 v1.1 可选）。
- A3 附件二进制存 SQLite（`attachment_blobs`，v2 起）；磁盘 `attachments/` 只作预览/打开缓存，可随时重建。
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
- （v2.0）Android APK / iOS TestFlight / macOS dmg / Linux AppImage
- （v3.0）RAG 服务与 API 文档

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
- **v2.0（多端 + 同步）**：`services/go_api/` 按 §7.5 起步；客户端把写入改为「本地库 + 同步队列」双写，
  `rev` / `device_id` / `deleted_at` 已预留。
- **v3.0（RAG）**：分块 + embedding + pgvector；API Key 只放服务端，上送需显式授权。
- 开发命令：`scripts/verify.ps1`（analyze + test + build）、`scripts/build.ps1`（含 `--no-tree-shake-icons`）。
