# 提交审查记录 — 2026-11-02 崩溃日志落盘

**范围**：实现 README 承诺但此前不存在的错误日志；补 3 个日志单测
**对应需求**：project.md 第 9 节交付物「崩溃日志」；风险 R1（中文输入法异常需现场证据）

## 1. 改动（diff 摘要）

| 文件 | 说明 |
|---|---|
| `lib/core/app_logger.dart`（新增） | `AppLogger.log()` 追加写 `logs/error.log`；超过 1 MB 轮转为 `error.old.log`；`install()` 挂 `FlutterError.onError` 与 `PlatformDispatcher.onError` |
| `lib/main.dart` | 启动即安装钩子；启动异常写入日志，并在失败页展示日志路径 |
| `test/app_logger_test.dart`（新增） | 写入含堆栈、超过 1 MB 轮转、root 为空回退系统临时目录 |

## 2. 原因

- README/数据位置表里写了「崩溃日志 `%APPDATA%\MDiary\logs\`」，但代码从未写过日志 ——
  文档与实现不一致，属于需要修的缺口。
- 验收里「中文输入法异常」「强杀进程」这类问题，用户描述往往不完整；有 `error.log`
  才能拿到异常栈。

## 3. 风险

- 【低】日志写入用同步 API 且包在 try/catch 内：磁盘满/只读目录不会影响主流程。
- 【低】`FlutterError.onError` 仍调用 `presentError`，debug 下的红屏行为不变。
- 【低】日志可能包含本地路径；文件留在用户自己的数据目录，不外传。

## 4. 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found! |
| `flutter test` | **51 passed**（24 纯逻辑 + 12 SQLite 集成 + 8 应用界面 + 4 Markdown 视图 + 3 日志） |
| `flutter build windows --release` | 成功 |

## 5. 回滚

`git revert <本提交sha>`。日志模块独立，回滚后仅失去日志能力，不影响数据与功能。
