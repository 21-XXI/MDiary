# 提交审查记录 — 2026-11-02 保存失败保留与重试

**范围**：修复「写库失败即丢 pending」；保存失败时状态栏可点击重试；补 4 个保存状态机用例
**对应需求**：project.md 目标 1（不丢稿）、6.2 验收 B1/B2、风险 R5（附件/写入失败）

## 1. 改动（diff 摘要）

| 文件 | 说明 |
|---|---|
| `lib/state/app_state.dart` | `flushNow()` 改为**写成功后才清 pending**；失败保留 pending，下一次 flush 自动重试；新增 `hasUnsavedChanges` |
| `lib/ui/widgets.dart` | `SaveIndicator` 增加 `onRetry`，失败态显示「保存失败 · 点此重试」并响应点击 |
| `lib/features/home_page.dart` | 状态栏把 `onRetry` 接到 `state.flushNow()` |
| `test/app_state_test.dart`（新增，4 用例） | 成功清 pending、失败保留并可重试、空 pending 的 flush 是空操作、切换条目前先落库 |

## 2. 原因

读 `flushNow()` 时发现顺序问题：

```dart
_pendingId = null;        // 先把待保存标记清了
try { entryRepo.saveContent(...) } catch (...) { _status = error; }
```

一旦写库抛错（磁盘满、数据库被占用、表损坏），pending 已被清空，**这份内容既没落库也不会再重试**——
用户只看到「保存失败」，继续输入会覆盖 pending，等于这段内容永久丢失。

修复：成功才清 pending；失败保留，任何后续 flush（继续输入、切换条目、Ctrl+S、关窗）都会自动重试。
同时把失败态做成可点击重试，用户能立刻手动重试而不用等下一次输入。

## 3. 风险

- 【低】失败后 pending 一直存在，反复重试可能产生多次失败写；但每次都是幂等 UPDATE，无副作用。
- 【低】失败时 `_entries` 不更新，列表显示旧内容——这是预期（数据库确实没写进去）。
- 【低】`SaveIndicator` 新增可选参数，其他调用点无需改动。

## 4. 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found! |
| `flutter test` | **93 passed**（新增 4 个保存状态机用例） |
| `flutter build windows --release` | 成功 |

关键断言（`test/app_state_test.dart`）：
- 正常保存后 `hasUnsavedChanges == false`、状态 `saved`；
- `DROP TABLE entries` 后 flush → 状态 `error`、`hasUnsavedChanges == true`；
- 再次 flush 仍然尝试写（说明 pending 未被清空）并再次报错；
- 切换条目前会先落库，切回后两篇内容都在。

## 5. 回滚

`git revert <本提交sha>`。回滚后写库失败会重新变成静默丢稿，不建议。
