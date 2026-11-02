# 提交审查记录 — 2026-11-02 客户端 v1.0 实现（code)

**范围**：Windows 桌面客户端首个可编译版本（数据层 + 状态层 + 界面层 + 单测）
**对应需求**：project.md 目标 1–4、第 6 节验收、7.1–7.4 技术约束

## 1. 改动（diff 摘要）

新增 20 个 Dart 文件 + 2 个测试文件 + Windows 工程脚手架：

| 区域 | 文件 | 行数 | 说明 |
|---|---|---|---|
| 入口 | `lib/main.dart`、`lib/app.dart` | ~120 | 启动装配、主题、启动失败兜底页 |
| 基础 | `core/app_paths.dart`、`formatters.dart`、`ids.dart`、`theme.dart` | ~230 | 数据目录、日期/字数格式化、uuid、主题 |
| 数据 | `data/database.dart`、`models.dart`、`*_repository.dart`、`attachment_store.dart`、`markdown_document.dart`、`markdown_io.dart` | ~800 | SQLite 连接与迁移、CRUD、内容寻址附件库、front matter 与导入导出 |
| 状态 | `state/app_state.dart`、`app_scope.dart` | ~380 | 列表/选中/自动保存调度/附件/导入导出 |
| 界面 | `features/home_page.dart`、`entry_editor_page.dart`、`trash_page.dart`、`settings_page.dart`、`ui/*` | ~1000 | 双栏布局、编辑器与预览、回收站、设置 |
| 测试 | `test/markdown_document_test.dart`、`formatters_test.dart` | ~200 | 24 个纯逻辑用例 |
| 平台 | `windows/`（脚手架） | 生成 | 窗口标题 MDiary、初始 1280×820 |

## 2. 原因

- 先交付「能编译、能跑、数据不丢」的最小闭环，再在此基础上做验收与打磨。
- 关键决定（与 architecture.md 偏差表一致）：
  1. 不引 drift/代码生成，手写 SQL + `PRAGMA user_version` 迁移，减少构建期失败面；
  2. 状态管理用内置 `ChangeNotifier`，不引 Riverpod；
  3. `sqlite3` 由 3.x 回退到 **2.9.4 + sqlite3_flutter_libs 0.5.42**：3.x 的 hooks 在构建期要从 GitHub 下载预编译 DLL，本机网络超时导致 `flutter test` 直接失败；
  4. 附件二进制存 `%APPDATA%\MDiary\attachments\<sha前两位>\<sha>.<ext>`，DB 只存引用。

## 3. 风险

- 【中】`sqlite3` 2.x 与 3.x API 有细微差异（本次只用到 `open/select/execute/close`，已在本机验证）；未来升级需回归。
- 【中】Markdown 渲染依赖 `flutter_markdown_plus`（社区续作），其 `imageBuilder` 行为需在验收时逐条确认（图片/缺失附件）。
- 【低】自动保存依赖 800ms 防抖 + 窗口失焦 flush；进程被强杀时可能丢最后 0.8 秒输入（验收 B3 会实测）。
- 【低】`file_picker` 13.x 为联邦插件新 API（`FilePicker.pickFile()` 静态方法），已在编译期验证；若后续升级注意破坏性变更。

## 4. 验证

在本机实际执行：

| 命令 | 结果 |
|---|---|
| `flutter pub get` | 成功，60 个依赖解析通过 |
| `dart analyze` | **No issues found!**（0 error / 0 warning / 0 info） |
| `flutter test` | **24 个用例全部通过** |
| `flutter build windows --release` | 见下一次提交（需 VS C++ 工具链安装完成） |

修复过的问题（记录以便复查）：
1. `AppScope` 与 `app.dart` 循环依赖 → 拆到 `state/app_scope.dart`；
2. `MarkdownBody` 无 `padding` 参数 → 外层包 `Padding`；
3. `parseDate` 会把 `2026-13-40` 规范化成 2027-02-09 → 增加范围与回读校验（单测覆盖）；
4. `scaffold` 的 `analysis_options.yaml` 中文注释在 `flutter pub get` 后仍为 UTF-8，无乱码。

## 5. 回滚

`git revert <本提交sha>` 可整体回退；数据库 schema 为新建表，无破坏性迁移，回退不影响已有数据。
