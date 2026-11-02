# 提交审查记录 — 2026-11-02 窄窗口布局修复 + 多尺寸布局回归

**范围**：编辑器工具栏与页脚改为可换行布局；新增 4 个多尺寸布局测试
**对应需求**：project.md 6.2 验收；F 组异常与边界（新增 F5 窄窗口、F6 日志落盘）

## 1. 改动（diff 摘要）

| 文件 | 说明 |
|---|---|
| `lib/features/entry_editor_page.dart` | 工具栏第二行由 `Row` 改为 `Wrap`（spaceBetween）；页脚两段文字由 `Row + Spacer` 改为 `Wrap` |
| `test/layout_test.dart`（新增） | 640/800/1024/1440 四个宽度 + 动态缩放，断言无 `RenderFlex` 溢出 |
| `docs/acceptance-v1.0.md` | 新增 F5（窄窗口布局）、F6（日志落盘）并回填 PASS |

## 2. 原因

- 之前只在 1280×820 下看过界面。推算 640 宽时右栏仅约 307px，页脚两段文字（约 350px）
  必然溢出；用布局测试复现，实测报 `A RenderFlex overflowed by 76 pixels on the right`。
- 工具栏在 800 宽时模式切换（约 330px）+ 4 个图标（192px）同样会溢出，一并改为 `Wrap`。
- 布局溢出在 release 下是静默裁切（按钮点不到），属于「用户会报、但开发看不出来」的问题，值得纳入自动回归。

## 3. 风险

- 【低】`Wrap` 在宽窗口下用 `spaceBetween` 保持左模式切换、右操作按钮的视觉位置，观感不变。
- 【低】窄窗口下工具栏可能占两行，编辑器可用高度略减，属可接受退化。
- 【低】布局测试依赖固定字号与系统字体度量，换机器（不同 DPI/字体）可能产生细微差异；
  断言只检查「是否溢出」，不检查像素位置，稳健性足够。

## 4. 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found! |
| `flutter test` | **56 passed**（24 纯逻辑 + 12 SQLite 集成 + 8 应用界面 + 4 Markdown 视图 + 3 日志 + 1 性能 + 4 布局） |
| `flutter build windows --release` | 成功 |

修复前后对比：修复前在 640×520 下 `RenderFlex overflowed by 76 pixels on the right`；
修复后同一用例通过，且 800/1024/1440 与动态缩放全部无异常。

## 5. 回滚

`git revert <本提交sha>`。纯布局与测试改动，无数据结构变更。
