# v1.1 验收清单

对应 `docs/project.md` 第 6 节。执行环境：Windows 10/11 x64，`flutter build windows --release --no-tree-shake-icons` 产物。
版本：**1.1.0**（2026-11-05）。上一版记录见 git 历史中的 `acceptance-v1.0.md`（本文件由它演进而来）。

> 状态列：`PASS` / `FAIL`（附现象）/ `BLOCKED`；标「自动」的项由 `flutter test` 覆盖，标「人工」的需要真机点一遍。

## A. 编译与质量门槛（6.1）

| # | 项 | 命令 / 操作 | 期望 | 状态 |
|---|---|---|---|---|
| A1 | 静态分析 | `flutter analyze` | 0 issue | **PASS**（2026-11-05 自动验证，0 issue） |
| A2 | 单元测试 | `flutter test` | 全部通过 | **PASS**（2026-11-05 自动验证，**181 passed**：核心逻辑 / 真实 SQLite / 界面 widget / 布局 / 迁移 / 多库 / 附件入库 / 拖拽 / 星图 / 标签 / 粘贴截图 / v1.1 收尾） |
| A3 | Release 构建 | `scripts\build.ps1` | 产出 `mdiary.exe` | **PASS**（2026-11-05，Release 目录 21.9 MB；打包产物独立启动建库通过） |
| A4 | 提交审查 | `git log` | 每条 commit 含改动/原因/风险/验证/回滚 | **PASS**（提交均按 `.gitmessage` 模板，`scripts/check-commits.ps1` 通过） |
| A5 | 交付包校验 | `SHA256SUMS.txt` | 与 zip 实际哈希一致 | **PASS**（`MDiary-1.1.0-windows-x64.zip`，13.7 MB，哈希见 `dist/SHA256SUMS.txt`） |

## B. 目标 1：书写并保存为 .md

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| B1 | 新建保存 | Ctrl+N → 输入标题与正文 → 等 1 秒 | 右上角显示「已保存」 | **自动**：800ms 防抖落库（`app_widget_test`）；人工确认提示文案 |
| B2 | 重开不丢 | 关闭程序再打开 | 内容完整 | **部分自动**：关窗强制落库（`app_widget_test`）；真机点 × 需人工确认 |
| B3 | 强杀不丢 | 编辑后 1 秒内结束进程 → 重开 | 最近一次已落库内容仍在 | 人工 |
| B4 | 中文输入 | 连续输入中文、英文、标点、emoji | 无乱码、无丢字 | 人工 |
| B5 | 长文性能 | 粘贴 10,000 字 | 滚动与输入流畅 | **部分自动**：10,000 字保存/重载/预览无异常；流畅度人工 |
| B6 | Markdown 语法 | 标题/列表/表格/代码块/引用/链接/图片 | 预览渲染正确 | **自动**：GFM 子集渲染无异常（`markdown_view_test`）；观感人工 |
| B7 | 导出单篇 | 编辑器「导出为 .md」 | 生成 `<日期>-<标题>.md` | **自动**：导出生成文件且内容含 front matter（`data_layer_test`） |
| B8 | 外部渲染 | VS Code / Typora 打开导出文件 | 排版正确、图片可见 | 人工 |
| B9 | 整库导出 | 设置 → 整库导出 | 全部 .md + `assets/` | **自动**：每篇 .md + 共用附件只存一份（`import_edge_test`、`export_shared_attachment_test`） |
| B10 | 导出已删除条目 | 删除后从编辑器导出 | 明确报错，不产生文件 | **自动**：`v11_test`「导出已删除的日记：报错而不是写幽灵文件」 |

## C. 目标 2：SQLite 本地存储

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| C1 | 库文件生成 | 首次启动后查看 `MDiaryData\db\` | 存在 `mdiary.sqlite` | **PASS**（打包产物实测：生成 `db\mdiary.sqlite`；`MDiaryData\` 下另有 `attachments\` 缓存与 `logs\`） |
| C2 | 重启保持 | 关闭再开 | 列表、正文、附件引用还原 | **自动**：`persistence_test` 关闭重开后条目/正文/附件引用/字节均还原 |
| C3 | 老布局迁移 | 把库放回 `MDiaryData\` 根目录再启动 | 自动搬进 `db\` | **PASS**（实测：根目录 `mdiary.sqlite` 被移入 `db\`，应用正常打开） |
| C4 | schema 升级 | 用 v1 库启动 | 自动建 `attachment_blobs`（v2），迁移前留 `.v1.bak` 快照 | **自动 + 人工**：`database_import_test` 覆盖布局迁移；schema 升级由 `AppDatabase` 迁移 + 备份逻辑覆盖，建议用 v1.0 归档库人工点一遍 |
| C5 | 多库互不污染 | 切到另一个库再切回 | 各自条目独立 | **自动**：`library_test`「切到空目录会新建空库，切回来数据还在」 |

## D. 目标 3：可查看

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| D1 | 时间轴列表 | 打开首页 | 按日期分组，最新在上，置顶最前 | 人工（逻辑由 `data_layer_test` 排序断言覆盖） |
| D2 | 详情预览 | 点击条目切「预览」 | 右侧渲染 Markdown | **自动**：`app_widget_test`「切换预览后渲染 Markdown」 |
| D3 | 搜索-中文 | 搜索框输入中文词 | 命中标题/正文/标签 | **自动**：`app_widget_test` 搜索用例 + `tag_test` 标签命中 |
| D4 | 搜索-英文 | 输入英文与大小写混合 | 不区分大小写命中 | 人工 |
| D5 | 千篇性能 | 1,000 篇打开与搜索 | 首屏 < 300ms，搜索 < 500ms | **PASS（实测）**：列表 50ms / 标题搜索 3ms / 正文全表 37ms；界面 1,000 篇首屏只建 6 项（`perf_test`、`app_widget_test`） |
| D6 | 置顶 | 菜单置顶 | 列表顶部固定 | **自动**：排序断言（`data_layer_test`） |
| D7 | 回收站恢复 | 删除 → 回收站 → 恢复 | 回到原日期分组 | **自动**：`state_interactions_test` |
| D8 | 彻底删除 | 回收站彻底删除 | 条目消失、附件回收 | **自动**：`persistence_test`、`v11_test`（含字节 GC） |
| D9 | 清空回收站 | 回收站 →「清空」 | 全部删除并回收附件 | **自动**：`v11_test`「清空回收站」；人工确认二次确认框 |

## E. 目标 4：附件

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| E1 | 插入图片 | 工具栏「附件」→ png | 正文 `![名](assets/<sha>.png)`，预览显示图片 + 彩色名字 | **自动**：`app_widget_test`「插入附件」断言正文引用 |
| E2 | 插入 PDF | 同上选 pdf | 正文 `[名](assets/<sha>.pdf)`，点击可打开 | 人工 |
| E3 | 插入任意文件 | 选 .zip / .xlsx | 同上 | 人工 |
| E4 | 大小限制 | 选 > 100 MB 文件 | 提示拒绝，不写库、不落盘 | **自动**：超限分支（注入 1 KB 上限的 store）被拒、正文无引用、附件表 0 行 |
| E5 | 附件字节入库 | 插入后查看 `db/mdiary.sqlite` | `attachment_blobs` 有该 sha、字节数一致 | **PASS（实测）**：拖入文件后 `attachments=1`、`attachment_blobs` 字节数 = 源文件大小 |
| E6 | 缓存可重建 | 删除 `attachments\` 后预览/打开 | 自动从库里重建缓存 | **自动**：`attachment_blob_test`「删掉磁盘缓存也能重建」 |
| E7 | 去重 | 同一文件插入两次 / 两篇引用同一附件 | 字节只存一份 | **自动**：`attachment_blob_test`、`export_shared_attachment_test` |
| E8 | 导出带附件 | 整库导出 | `assets/` 内含文件，md 相对路径可渲染 | **自动**：导出从库里读字节写回 `assets/` |
| E9 | 导入还原 | 从导出目录再导入 | 附件复制回库，预览正常 | **自动**：`import_edge_test` |
| E10 | 拖拽导入 | 从资源管理器拖文件进窗口 | 挂到当前日记并插入引用 | **PASS（实测）**：模拟 `WM_DROPFILES` → entries/attachments 各 1、正文带引用；真人拖拽建议复测 |
| E11 | 粘贴截图 | 截图后 `Ctrl+Shift+V` / 工具栏按钮 | 生成 `截图-<时间>.png` 并插入 | **自动**：`paste_screenshot_test`（注入剪贴板字节）；真机剪贴板读取需人工确认 |

## F. 异常与边界

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| F1 | 中文/空格路径 | 程序放含中文/空格目录运行 | 正常启动与读写 | 人工 |
| F2 | 只读目录 | 附件缓存目录只读后插入 | 提示失败、不崩溃、内容保留 | **部分自动**：写入抛错、不产生记录（`persistence_test`）；真实 ACL 人工 |
| F3 | 空草稿 | Ctrl+N 后直接离开 | 不产生空条目 | **自动**：`app_widget_test`「空草稿在切换条目时被清理」 |
| F4 | 大库启动 | 1,000 篇重启 | 启动到可用 < 3s | 人工 |
| F5 | 窄窗口布局 | 拖到 640×520 再拖回 | 无溢出、按钮可点 | **自动**：`layout_test` 覆盖 640×520 / 800×600 / 1024×720 / 1440×900 |
| F6 | 最小窗口 | 试图把窗口缩到很小 | 停在约 720×520（按 DPI） | 人工（runner `WM_GETMINMAXINFO`） |
| F7 | 单实例 | 启动两个 `mdiary.exe` | 第二个激活已有窗口并退出 | **PASS（实测）**：二次启动后进程数仍为 1 |
| F8 | 日志落盘 | 检查 `MDiaryData\logs\error.log` | 异常时写入，超 1 MB 轮转 | **自动**：3 个日志用例 |
| F9 | 写库失败 | 磁盘满/库被占用时继续输入 | 提示失败、内容不丢、可重试 | **自动**：`app_state_test` 保留 pending 且可重试 |
| F10 | 库文件被占用 | 打开库时另一个进程持有写锁 | 明确报错，不损坏库 | 人工 |
| F11 | 打开路径含特殊字符 | 数据目录/附件路径含 `&`、`%` | 能正常用系统程序打开 | **自动（逻辑）**：改走 `ShellExecuteW`，不再经 cmd 解析；人工复测 |

## G. v1.1 新增：多库 / 导入 / 合并

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| G1 | 自定义库目录 | 设置 →「切换 / 新建库」选一个自定义名字的目录 | 使用该目录（`<目录>\mdiary.sqlite`），`libraries.json` 记住 | **自动**：`library_test`「切到空目录会新建空库，切回来数据还在」 |
| G2 | 重启记住库 | 切库后关闭再打开 | 回到上次的库 | **PASS（实测）**：`libraries.json` 指向自定义库时启动即打开该库 |
| G3 | 导入新库 | 选目录 → 选 `.sqlite` → 命名 → 导入 | 复制到 `libraries\<名字>\` 并切换；源文件不动 | **自动**：`library_test`「导入新库」 |
| G4 | 合并库（同 id） | 选另一个库 → 合并 | 同 id 保留 `updated_at` 较新的；新条目追加 | **自动**：`library_test`「合并库：同 id 保留较新的」 |
| G5 | 合并去重 | 两库含同一附件 | 索引按 (entry, sha) 去重、字节按 sha 去重 | **自动**：同上，`blobsAdded == 0` |
| G6 | 合并自己 | 选当前库合并 | 拒绝并提示 | **自动**：`library_test` |
| G7 | 坏库/新版本库 | 选非 SQLite 或更高 schema 的库 | 拒绝，当前库不受影响 | **自动**：`library_test`、`database_import_test` |
| G8 | 覆盖当前库（旧入口） | （API 级）`importDatabase` | 先备份 `mdiary.sqlite.bak-<时间>`，失败回滚 | **自动**：`database_import_test` |

## H. v1.1 新增：界面增强

| # | 项 | 操作 | 期望 | 状态 |
|---|---|---|---|---|
| H1 | 日历 | 左栏点某天 | 有则打开、无则新建当天日记；有日记的日期带圆点 | **自动**：`calendar_test`、`app_widget_test` |
| H2 | 星图 | 点左栏 ✳ | 全部/年/月/周 分组，点日记星回编辑器，点附件星打开 | **自动**：`star_map_test`、`app_widget_test` |
| H3 | 星图共用附件 | 两篇引用同一附件 | 只画一颗星、连两条线 | **自动**：`star_map_test` |
| H4 | 标签 | 编辑器「添加标签」 | 列表可见、搜索命中、导出 front matter、导入读回 | **自动**：`tag_test`、`app_widget_test` |
| H5 | 附件名可点 | 预览含图片的日记 | 图片下方彩色名字标签，点击打开附件 | **自动**：`markdown_view_test` |
| H6 | 暗色主题 | 设置切深色 | 全部页面配色正常 | 人工 |

## I. 汇总（2026-11-05）

- 自动验证：`flutter analyze` 0 issue、`flutter test` **181 passed**、`flutter build windows --release` 成功、`scripts/verify.ps1` 全流程通过。
- 交付物：`dist/MDiary-1.1.0-windows-x64/`、`dist/MDiary-1.1.0-windows-x64.zip`（13.7 MB）、`dist/SHA256SUMS.txt`。
- 待人工确认项（建议验收时逐条点）：B3/B4/B5/B8、D1/D4、E2/E3、F1/F2/F4/F6/F10/F11、H6。
