# MDiary v1.0 架构设计

> 对应需求：`docs/project.md` 第 3 节目标 1–4、第 7 节技术约束。本文只覆盖 v1.0（Windows 桌面），
> 后端同步（v2.0）与 RAG（v3.0）仅预留字段，不实现。

## 1. 分层与目录

```
apps/client_flutter/
  lib/
    main.dart                 入口：初始化数据库、附件库、启动失败兜底页
    app.dart                  MaterialApp + AppScope（InheritedNotifier）
    core/
      app_paths.dart          数据目录解析（默认 exe 同目录 MDiaryData；mdiary-location.txt
                              记住用户改过的位置；MDIARY_HOME 覆盖；不可写时逐级回退）
      file_drop_channel.dart  接收 runner 转发进来的拖拽文件路径
      theme.dart              主题、字号、编辑器字体
      formatters.dart         日期/字数/字节格式化
      ids.dart                uuid v4 / device_id
    data/
      database.dart           sqlite3 连接、PRAGMA、PRAGMA user_version 迁移
      models.dart             Entry / Attachment 不可变模型
      entry_repository.dart   条目读写（唯一写入路径）
      attachment_repository.dart
      meta_repository.dart    key-value 配置
      attachment_store.dart   内容寻址附件库（sha256）
      tag_repository.dart     标签多对多（tags / entry_tags，含孤儿标签清理）
      markdown_document.dart  front matter 解析/生成、文件名规范化（纯函数，可单测）
      markdown_io.dart        .md 导出/导入（附件搬运）
      data_root_migration.dart 数据目录迁移：逐文件复制 + 大小校验 + 删旧目录
    state/
      app_state.dart          ChangeNotifier：列表、选中、自动保存调度
    features/
      home_page.dart          双栏：列表 + 编辑区、快捷键、状态栏
      entry_editor_page.dart  标题/正文/工具栏/附件条/预览
      star_map/
        star_map_layout.dart  星图布局与命中测试（纯函数，可单测）
        star_map_page.dart    星图画布、时间分组、点击打开
      trash_page.dart         回收站
      settings_page.dart      外观、数据、导入导出、关于
    ui/
      month_calendar.dart     左栏月历（7 列紧凑网格，点日期 = 打开/新建当天日记）
      markdown_view.dart      Markdown 渲染 + 本地附件解析
      widgets.dart            列表项、保存指示、空状态
  test/                       纯逻辑单测
```

约定：`features` 只通过 `repositories` / `services` 触达数据，不直接持有 `AppDatabase`；
UI 不写 SQL；所有写操作走仓储，便于 v2.0 换成「本地库 + 同步队列」双写。

## 2. 数据模型（SQLite / drift）

```sql
CREATE TABLE entries (
  id          TEXT PRIMARY KEY,           -- uuid v4
  title       TEXT NOT NULL DEFAULT '',
  body_md     TEXT NOT NULL DEFAULT '',
  entry_date  INTEGER NOT NULL,           -- 日记归属日（本地时间）
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  rev         INTEGER NOT NULL DEFAULT 1, -- 预留：同步冲突判定
  deleted_at  INTEGER,                    -- 软删除，回收站
  pinned      INTEGER NOT NULL DEFAULT 0,
  device_id   TEXT NOT NULL               -- 预留：v2.0 多端来源
);

CREATE TABLE attachments (
  id          TEXT PRIMARY KEY,
  entry_id    TEXT NOT NULL REFERENCES entries(id),
  sha256      TEXT NOT NULL,              -- 内容寻址，天然去重
  filename    TEXT NOT NULL,
  mime        TEXT NOT NULL,
  size_bytes  INTEGER NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE INDEX idx_attachments_entry ON attachments(entry_id);
CREATE INDEX idx_attachments_sha   ON attachments(sha256);

CREATE TABLE tags (
  id    TEXT PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE
);
CREATE TABLE entry_tags (
  entry_id TEXT NOT NULL,
  tag_id   TEXT NOT NULL,
  PRIMARY KEY (entry_id, tag_id)
);

CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

**为什么附件二进制不入库**（project.md A3）：库文件保持 KB 级，备份/迁移快；sha256 去重；
v2.0 同步时按 hash 上传即可幂等。代价是「文件已写、记录未写」的中间态，靠启动 GC 兜底。

## 3. 关键流程

### 3.1 编辑与自动保存
输入 → `EntryEditorController` 本地状态立即更新（无阻塞）→ 800ms 防抖 → 仓储 `upsert(body, rev+1)`。
保存状态机：`saved → dirty → saving → saved | failed(重试按钮)`。离开页面/关闭窗口强制 flush。

### 3.2 新建与删除
新建：立即插入空条目（草稿），`entry_date` 取当天 00:00。空草稿离开时若标题正文皆空则物理删除，避免垃圾条目。
删除：`deleted_at` 置位（进回收站）；回收站「彻底删除」→ 删附件记录 → 触发 GC → 删条目。

### 3.2.1 日历
左栏 `MonthCalendar` 只负责画格子（月/选中日/有日记的日期，来自 `EntryRepository.datesWithEntries()`；
`refresh()` 时刷新）。点某天走 `AppState.selectDay()`：
`EntryRepository.findLatestOn(day)` 命中就 `select()` 打开最近更新的一篇，没命中就
`createEntry(date: day)` 并 `refresh()` 按日期重排；列表里点开某篇时反过来把日历跳到它的月份。
初始选中日 = 今天与最新一篇里更晚的那天（`_latestDay()`）。

> 图标坑：release 构建默认会做图标树摇，只保留「常量 `IconData` 直接写在 `Icon()` 构造处」的图标；
> 把 `Icons.x` 当参数传进包装组件会被裁掉，debug 正常、release 变空白按钮。
> 因此 `scripts/build.ps1` 统一加 `--no-tree-shake-icons`（图标字体全量约 1.6 MB），
> 新增图标时不用再逐个验证是否被保留。

### 3.3 附件
1. `file_picker` / 拖拽 / 剪贴板拿字节 → sha256；
2. **字节写进数据库** `attachment_blobs (sha256 PK, size, bytes)`（同 sha 只存一份），
   磁盘 `<数据目录>\attachments\<hash[0:2]>\<hash>.<ext>` 只作为预览/打开的**缓存**；
3. 插 `attachments` 行（日记 → sha 的索引关系）；单文件上限 100 MB；
4. 正文插入带**原文件名**的引用：图片 `![西湖.png](assets/<hash>.png)`，普通文件
   `[会议纪要.pdf](assets/<hash>.pdf)`——纯文本 .md 里也能看出是什么附件，导出/导入仍按普通
   Markdown 解析（`markdownLinkPattern` 保持不变，alt 文本原样保留）。
5. 预览时 `MarkdownView` 的 `imageBuilder` 把图片画出来，并在下方渲染一个彩色「附件名」标签
   （`resolveName` 用数据库里的文件名兜底老数据），点标签或图片走 `onOpenLink` → 系统默认程序打开。
   普通附件链接同样可点。
6. 打开/预览前 `AttachmentStore.pathFor()` 会确保缓存存在：缓存丢了就从库里的字节重建。
   老版本（v1，附件只在磁盘）升级时 `backfillFromFiles()` 在启动阶段把文件搬进库（幂等）。

### 3.4 导出
- 单篇：`<日期>-<标题>.md`，头部写 YAML front matter（title/date/tags），正文原样。
- 整库：目录下逐个 .md + `assets/` 附件副本；相对路径 `assets/<hash>.<ext>` 保证 Typora/VS Code 可直接渲染。
- 附件字节从 `attachment_blobs` 读出后写成普通文件（老数据缺 blob 时回落到磁盘缓存）；
  同 sha 在一个导出目录里只写一份，但每篇 .md 都引用它。
- 导出前统一 LF、UTF-8 无 BOM（project.md R6）。

### 3.5 导入
选目录 → 递归 `*.md` → 解析 front matter（缺失则用文件名和 mtime）→ 正文中相对图片（`assets/…` 或 `./img/…`）存在则复制进附件库并改写为 `assets/<hash>.<ext>` → 建条目。导入按「文件路径 + 内容 hash」去重，重复导入不产生副本。

### 3.6 搜索
v1.0 用 `LIKE '%kw%'` 覆盖标题、正文与**标签名**（`id IN (SELECT et.entry_id FROM entry_tags et
JOIN tags t ON t.id = et.tag_id WHERE t.name LIKE ?)`；中文子串匹配准确，1k 篇量级毫秒级）。
FTS5 trigram 作为 v1.1 优化项：届时只替换 `EntryRepository.query` 的实现，界面不变。

### 3.6.1 标签
`TagRepository.setTags(entryId, names)` 覆盖式写入：去空白、忽略大小写去重、自动清掉没人引用的标签；
`AppState.refresh()` 一次查出 `entry_id -> [name]` 供列表与编辑器渲染。
导出写进 front matter 的 `tags: [...]`，导入时 `setTags` 落库。

### 3.7 数据目录切换
设置页「更改数据目录」→ 原生目录选择器 → 校验目标（必须是空目录、不能与当前目录嵌套）→
`flushNow()` → `wal_checkpoint(TRUNCATE)` 并关库 → `DataRootMigration.run()` 复制数据库/附件/日志
并逐文件比对大小 → 新库试开 → 写 `mdiary-location.txt` → 换绑定（db / 仓储 / 附件库 / markdownIo）→
重新 `bootstrap()` → 删旧目录（只删本程序管理的文件；旧目录里装着 exe 时一律不动）。
任一步失败：指针与连接都回到旧目录，旧数据原样保留，异常抛给设置页提示。

### 3.8 星图（全部 / 年 / 月 / 周）
`features/star_map/star_map_layout.dart` 是纯布局：按周期把日记分桶（年 / 月 / 周一起点 / 全部），
桶内排 3 列网格；附件按 sha 分组，**同一个 sha 只产生一颗附件星**，被 N 篇索引就连 N 条线
（`refCount > 1` 画成带环的「共用星」）。`StarMap.hitTest` 命中日记星 / 附件星；
`star_map_page.dart` 用 `CustomPainter` 画星星与连线，`InteractiveViewer` 负责缩放平移，
点日记星 `pop(entry)` 回到主界面并 `select()`，点附件星走 `openInSystem()`。
布局与命中都无 IO，单测直接喂 `Entry` / `Attachment` 列表。

### 3.9 拖拽导入附件（Windows）
`flutter_window.cpp` 里 `DragAcceptFiles(hwnd, TRUE)` + 处理 `WM_DROPFILES`，把路径转 UTF-8 后经
`mdiary/drop` 方法通道的 `files` 方法发给 Dart（`core/file_drop_channel.dart` 安装回调）。
`AppState.attachDroppedFiles()`：没有选中日记就先 `createEntry()`，逐个 `attachPath()`，
再把 `assets/<sha>.<ext>` 引用追加进正文并 `flushNow()`（否则导出的 .md 只有附件没有引用）。
超限 / 被占用的单个文件跳过，不影响其余文件。

## 4. 依赖清单

| 包 | 用途 | 备注 |
|---|---|---|
| sqlite3 2.x + sqlite3_flutter_libs | 本地库 | 包内自带各平台预编译 SQLite，构建期不需要访问 GitHub（3.x 的 hooks 会下载 DLL，国内网络不可达） |
| path | 路径拼接 | 纯 Dart |
| crypto | sha256 | 附件寻址 |
| file_picker | 选文件 / 选目录 | Windows 原生对话框 |
| flutter_markdown_plus | Markdown 渲染 | `flutter_markdown` 停止维护后的社区续作 |
| dart:io（内置） | 数据目录、打开文件 | 不引入 path_provider / open_filex |
| ChangeNotifier（内置） | 状态管理 | 单窗口应用够用，少一层依赖 |

刻意不引入：riverpod / go_router / drift / shared_preferences / window_manager / desktop_drop /
open_filex —— 每多一个依赖就多一类首次编译失败与版本冲突的可能，v1.0 用内置能力覆盖。

## 5. 与需求的偏差登记

| 项 | project.md 原文 | v1.0 实现 | 处理 |
|---|---|---|---|
| 附件投递方式 | 拖拽 + 粘贴 + 菜单 | 菜单（file_picker） | 拖拽需 desktop_drop 插件，v1.1 评估 |
| 搜索 | FTS5 trigram | LIKE 子串 | 子串命中准确，1k 篇实测后决定是否上 FTS5 |
| 工作区（Vault） | 用户自选目录 + assets/ | 固定 `%APPDATA%\MDiary`，导出时生成 assets/ | v1.1 支持迁移目录 |
| ORM | drift + 代码生成 | 手写 SQL + sqlite3（`database.dart`） | schema 小且固定，去掉 build_runner 这一失败面 |
| 状态管理 | Riverpod | ChangeNotifier + InheritedNotifier | 单窗口应用无跨页共享需求 |
| 路由 | go_router | Navigator.push | 仅 4 个页面，不需要声明式路由 |

## 6. 验证方式

- `flutter analyze`（0 issue）、`flutter test`（纯逻辑单测：front matter 解析、导出文件名规范化、sha256 寻址、搜索高亮）。
- `flutter build windows --release` 产出 `build\windows\x64\runner\Release\mdiary.exe`。
- 手工验收按 `docs/acceptance-v1.1.md` 逐条勾选。
