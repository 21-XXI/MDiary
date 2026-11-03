# 数据库 schema（客户端 SQLite）

文件位置：`%APPDATA%\MDiary\mdiary.sqlite`
连接参数：`journal_mode=WAL`、`synchronous=NORMAL`、`foreign_keys=ON`
版本管理：`PRAGMA user_version`，当前 **1**。迁移在 `lib/data/database.dart` 的 `_migrate()` 中按
「版本号递增 + 单事务」执行，升级前不会删除任何既有数据。

## entries（日记条目）

| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | uuid v4（`core/ids.dart`） |
| title | TEXT NOT NULL DEFAULT '' | 标题，可空串；列表展示时回落为正文首行 |
| body_md | TEXT NOT NULL DEFAULT '' | Markdown 正文，唯一内容真源 |
| entry_date | INTEGER NOT NULL | 日记归属日（本地 00:00 的毫秒时间戳），用于按天分组 |
| created_at | INTEGER NOT NULL | 创建时间 |
| updated_at | INTEGER NOT NULL | 最后写入时间（列表排序、状态栏展示） |
| rev | INTEGER NOT NULL DEFAULT 1 | 每次内容写入 +1；v2.0 同步用于冲突判定 |
| deleted_at | INTEGER NULL | 软删除时间；非空即「在回收站」 |
| pinned | INTEGER NOT NULL DEFAULT 0 | 置顶（列表排序优先） |
| device_id | TEXT NOT NULL DEFAULT '' | 本机 uuid；v2.0 多端来源标记 |

索引：`idx_entries_date (entry_date DESC)`、`idx_entries_deleted (deleted_at)`。

## attachments（附件引用）

| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | uuid v4 |
| entry_id | TEXT NOT NULL | 外键 → entries.id，`ON DELETE CASCADE` |
| sha256 | TEXT NOT NULL | 内容哈希，决定磁盘路径 |
| filename | TEXT NOT NULL | 原始文件名（展示、推断扩展名与 MIME） |
| mime | TEXT NOT NULL | 由扩展名推断 |
| size_bytes | INTEGER NOT NULL | 文件大小（≤ 25 MB） |
| created_at | INTEGER NOT NULL | 插入时间 |

索引：`idx_attachments_entry (entry_id)`、`idx_attachments_sha (sha256)`。

二进制**不入库**：落盘于
`%APPDATA%\MDiary\attachments\<sha 前两位>\<sha><ext>`，
同一内容多次插入只存一份（内容寻址去重）。

## tags / entry_tags（v1.0 标签）

`tags(id, name UNIQUE)` 与 `entry_tags(entry_id, tag_id)` 已启用：

- 编辑器标题下方的「添加/编辑标签」写入，逗号/空格分隔，去重忽略大小写；
- 搜索框同时匹配**标题、正文、标签名**（`entry_tags JOIN tags` 子查询）；
- 导出写进 front matter 的 `tags: [a, b]`，导入时读回并落库；
- 没有任何日记引用的标签会被自动清掉，避免越攒越多。

## app_meta（键值配置）

| key | 取值示例 | 用途 |
|---|---|---|
| device_id | uuid | 本机标识，首次启动生成 |
| theme_mode | system / light / dark | 主题 |
| editor_font_size | 16 | 编辑器字号 |

## 数据生命周期

1. **写入**：编辑器输入 → 800ms 防抖（或 Ctrl+S / 窗口失焦）→ `entries` upsert，`rev+1`。
2. **删除**：`deleted_at` 置位（回收站，附件保留）。
3. **彻底删除**：删 `attachments` 行 → 删 `entries` 行 → 触发孤儿附件 GC。
4. **GC**：`AttachmentStore.collectGarbage(referencedHashes)` 删除磁盘上无引用的文件；
   设置页「清理孤儿附件」可手动触发。

## 备份与迁移

- 备份：复制整个 `%APPDATA%\MDiary`（含 WAL 文件），或使用「整库导出」得到纯 Markdown。
- 跨端迁移（v2.0）：以 `entries.id` + `rev` + `updated_at` 为同步元组，附件按 `sha256` 幂等上传。
