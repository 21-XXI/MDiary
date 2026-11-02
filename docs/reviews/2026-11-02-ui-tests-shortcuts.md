# 提交审查记录 — 2026-11-02 界面级测试与快捷键修正

**范围**：5 个无头 widget 测试、全局快捷键实现方式调整、编辑器控件测试锚点
**对应需求**：project.md 目标 1/3（书写、自动保存、查看）、6.2 验收 B1/B2/D1

## 1. 改动（diff 摘要）

| 文件 | 说明 |
|---|---|
| `lib/features/home_page.dart` | 全局快捷键从 `CallbackShortcuts` 改为 `Focus.onKeyEvent` 显式处理（Ctrl+N / Ctrl+S / Ctrl+F / Esc） |
| `lib/features/entry_editor_page.dart` | 标题、正文输入框加 `Key('editor-title')` / `Key('editor-body')` 测试锚点 |
| `test/app_widget_test.dart`（新增） | 5 个界面级用例：自动保存防抖、预览渲染、Ctrl+N、中文搜索、空草稿清理 |

## 2. 原因

- 手工冒烟时 Ctrl+N 未生效，无法判断是「焦点问题」还是「实现问题」；补无头测试后定位到：
  **快捷键本身可用，之前失败是桌面焦点被抢占 + 测试用例前置条件不对**（第一篇是空草稿，
  Ctrl+N 切换时被「空草稿清理」逻辑正确删除，看似没新建）。
- 用 `Focus.onKeyEvent` 替代 `CallbackShortcuts`：事件从任意被聚焦子控件冒泡上来都能处理，
  行为可测（调试输出确认 `KeyDownEvent N ctrl=true` 收到）；输入框内的普通字符仍返回 `ignored`，
  不影响打字。
- 加测试锚点是为了让 UI 测试不依赖「第几个 TextField」这种脆弱定位。

## 3. 风险

- 【低】`Focus.onKeyEvent` 在输入法组合态下的按键处理需真人验证（无头测试覆盖不到 IME）。
  若发现中文输入时快捷键抢键，可改为「仅当焦点不在文本输入框时处理」。
- 【低】新增 `Key` 不改变布局与行为。
- 【中】widget 测试依赖 `sqlite3.dll`（发布产物内），CI 首次需先构建；缺失时整组自动跳过。

## 4. 验证

`powershell -File scripts\verify.ps1`：

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found!（0 issue） |
| `flutter test` | **41 passed**（24 纯逻辑 + 12 SQLite 集成 + 5 widget） |
| `flutter build windows --release` | 成功 |

widget 测试断言要点：
1. 输入后 300ms 未落库、900ms 后标题与正文已写入（防抖边界）；
2. 切到「预览」后出现 `MarkdownView` 且能命中正文文字；
3. Ctrl+N 后出现新的空条目，输入内容后库内 2 条；
4. 中文子串搜索命中/无结果/清空恢复；
5. 空草稿在切换时被物理删除，已有内容的条目保留。

## 5. 回滚

`git revert <本提交sha>`。快捷键实现回退后功能仍可用（CallbackShortcuts 版本曾通过冒烟），
测试文件为新增，无数据影响。
