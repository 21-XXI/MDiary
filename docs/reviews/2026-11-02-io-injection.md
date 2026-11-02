# 提交审查记录 — 2026-11-02 文件对话框可注入 + 导出/导入/附件界面测试

**范围**：把系统文件对话框从 UI 中解耦为可注入依赖；补导出、整库导出、从目录导入、插入附件的界面级测试
**对应需求**：project.md 目标 1（导出 .md）、目标 4（附件）、6.2 验收 B7 / B9 / E1 / E8

## 1. 改动（diff 摘要）

| 文件 | 说明 |
|---|---|
| `lib/state/app_state.dart` | 新增 `PickedFile` + `SingleFilePicker` / `DirectoryPicker` 类型；构造可注入，默认实现仍走 `file_picker`；新增 `dataRootPath` 注入字段 |
| `lib/main.dart` | 装配时传入 `dataRootPath: AppPaths.root.path` |
| `lib/features/settings_page.dart` | 不再直接依赖全局 `AppPaths`，改读 `state.dataRootPath`（去掉了对全局单例的耦合） |
| `test/app_widget_test.dart` | 新增 3 个界面用例：工具栏导出、插入附件、设置页整库导出 + 从目录导入；并注入假对话框 |

## 2. 原因

- 之前导出/导入/附件插入只有数据层测试，`FilePicker` 静态调用无法在测试中驱动，
  等于验收清单里 B7/B9/E1/E8 完全靠人工点。
- 把「选文件/选目录」抽成函数注入后，测试可以给出确定的返回值，从而验证**完整链路**：
  点按钮 → 取路径 → 写文件/写库 → 界面刷新。
- 顺带修掉一个真实耦合：`SettingsPage` 直接读 `AppPaths.root`，在 `AppPaths.init()` 未执行时
  （测试、以及未来任何非标准启动路径）会抛 `LateInitializationError`。改为由 `AppState` 注入。

## 3. 风险

- 【低】`AppState` 构造签名新增可选参数，现有调用（main/测试）兼容。
- 【低】`dataRootPath` 默认为空串，若装配时忘了传，设置页会显示空路径（不影响功能）。
- 【中】widget 测试中「触发真实文件 IO 的点击」必须在 `tester.runAsync` 内执行，
  否则 fake-async 下 `File.writeAsBytes` 永不完成（本轮已踩坑并注释说明），后续加测试需遵守。

## 4. 验证

`powershell -File scripts\verify.ps1`：

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found! |
| `flutter test` | **48 passed**（24 纯逻辑 + 12 SQLite 集成 + 8 应用界面 + 4 Markdown 视图） |
| `flutter build windows --release` | 成功 |

新增界面用例断言：
1. 工具栏「导出为 .md」→ 目标目录出现 1 个 `.md`，内容含标题与正文；
2. 「插入附件」→ 正文出现 `![](assets/<hash>.png)`、附件表 +1、附件库落盘 1 个文件；
3. 设置页「整库导出」→ 目录生成 `.md`；「从目录导入 .md」→ 条目数 2 且标题为导入内容。

## 5. 回滚

`git revert <本提交sha>`。数据层未改 schema，回滚不影响数据；注入参数有默认值，回滚后行为不变。
