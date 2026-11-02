# 提交审查记录 — 2026-11-02 构建适配与冒烟验证

**范围**：中文路径构建适配、编辑器工具栏布局修复、真实 SQLite 集成测试、schema 文档
**对应需求**：project.md 第 6 节验收（编译成功）、7.3 目录结构、9 交付物清单

## 1. 改动（diff 摘要）

| 文件 | 说明 |
|---|---|
| `scripts/build.ps1`（新增） | 仓库路径含非 ASCII 时自动创建 `C:\mdiary_build` 联接并从该路径构建 |
| `scripts/verify.ps1`（改） | 构建改为调用 `build.ps1`，不再直接 `flutter build`；`analyze`/`test` 保持不变 |
| `apps/client_flutter/lib/features/entry_editor_page.dart` | 工具栏由「标题 + 分段按钮 + 4 个图标」单行改为两行：第一行标题，第二行模式切换与操作 |
| `apps/client_flutter/test/data_layer_test.dart`（新增） | 12 个真实 SQLite 集成用例（见下） |
| `docs/schema.md`（新增） | 表结构、索引、数据生命周期、备份与 v2.0 预留说明 |
| `README.md` | 补充构建脚本用法与「为什么中文路径不行」 |
| 其余 20 个 lib/test 文件 | `dart format` 全量格式化（仅缩进/折行，无逻辑改动） |
| `scripts/*.ps1` 编码 | 改为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 按 GBK 解析中文注释会报语法错误 |

## 2. 原因

1. **构建失败根因**：`flutter build windows` 的 CMake/MSBuild 链路把工程路径按 ANSI(GBK) 转码，
   日志里出现 `C:\...\锟斤拷志\...\app.dill`，导致 `Unable to read file`。仓库改英文目录的方案经确认不采用
   （用户决定保留 `日志`），因此改为「ASCII 目录联接 + 脚本构建」，仓库位置与 Git 历史不变。
2. **工具栏溢出**：1280 宽度下右栏「预览」段与 4 个图标按钮被裁掉（截图确认）。改两行布局后，
   第二行独占整行宽度，窄窗口下也不会溢出。
3. **测试覆盖不足**：原 24 个用例只覆盖纯函数，DB/附件/导入导出没有任何自动化验证；
   新增集成测试用发布产物里的 `sqlite3.dll` 做真实 SQLite 验证。

## 3. 风险

- 【中】`build.ps1` 依赖 `flutter` 在 PATH 中；脚本会打印明确错误，但不会自动找 SDK。
- 【中】联接路径固定为 `C:\mdiary_build`，若该目录被其他工程占用会被覆盖（脚本先比对 Target，不一致才重建）。
- 【低】`dart format` 改动面较大（20 文件），已确认无逻辑变更：`git diff -w` 仅剩工具栏与测试相关改动。
- 【低】集成测试在缺少 `sqlite3.dll` 的环境自动跳过（`MDIARY_SQLITE_DLL` 可显式指定），不会误报。

## 4. 验证

本机实际执行（`powershell -File scripts\verify.ps1`）：

| 项 | 结果 |
|---|---|
| `flutter pub get` | 成功 |
| `flutter analyze` | 0 issue（无 error / warning / info） |
| `flutter test` | **36 passed**（24 纯逻辑 + 13 集成，集成用例含真实 SQLite） |
| `flutter build windows --release` | 成功，`Release` 目录 21.8 MB，含 `mdiary.exe` / `data` / `flutter_windows.dll` / `sqlite3.dll` |

集成测试覆盖：schema 与 `user_version`、条目 CRUD、中文关键字搜索、LIKE 通配符转义、
置顶排序、软删除/恢复/彻底删除、重复导入判定、附件 sha256 去重、25 MB 上限、孤儿附件 GC、
单篇导出（front matter + assets/）、整库导出后导入还原与重复跳过。

冒烟测试（release 产物，`MDIARY_HOME=C:\md_smoke`）：
- 启动后自动创建 `%MDIARY_HOME%\MDiary\mdiary.sqlite`（WAL 模式）与 `attachments/`；
- 界面渲染正常（左栏列表 + 搜索 + 新建，右栏空状态提示）；
- 点击「新建日记」后列表出现「2026-11-02 / 无标题」条目，编辑器标题与正文占位提示正常；
- 关闭并重启程序，条目仍在（SQLite 持久化生效）。

## 5. 回滚

`git revert <本提交sha>`。构建脚本为新增文件，回滚后可直接用 `flutter build`（限 ASCII 路径）。
数据库无 schema 变更（仍是 v1），回滚不影响已产生的数据。
