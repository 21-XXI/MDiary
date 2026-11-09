# MDiary v2.5.0 发布说明（Windows x64）

发布日期：2026-11-09　｜　版本：`2.5.0+10`　｜　基于 v2.4.0

## 1. 数学公式

- 行内：`$E=mc^2$`；
- 块级：`$$ ... $$`（单行或多行），居中显示；
- 渲染用 `flutter_math_fork`（纯 Dart，无 WebView、离线可用）；
- 解析失败显示红色错误块 + 原始 TeX，不会让整段内容消失；
- 编辑器工具栏新增「符号与公式」面板，常用 TeX 片段一键插入。

## 2. Mermaid 图（源码卡片）

` ```mermaid ` 围栏块会在预览里显示「Mermaid 图」卡片：保留完整源码、一键复制，
可粘贴到 mermaid.live 查看渲染。

> **未做真实渲染**：`webview_windows` 依赖 NuGet 上的 WebView2 SDK，当前构建机无法获取
> （`nuget install Microsoft.Web.WebView2` 失败），构建直接中断；为避免交付一个构建不出来的版本，
> 2.5 先以源码卡片交付，真渲染单独排期（需要可访问 NuGet 的构建环境或内置 SDK）。

## 3. 常用符号提示表

编辑器 →「符号与公式」：Markdown 结构、数学公式、希腊字母、箭头、逻辑与集合、常用符号六组；
有选区时包裹选区，无选区时插入占位符并选中，可连续插入。

## 4. 主题与字体设置

设置 → 外观（在原有主题、字号基础上新增）：

- 界面字体：默认 / 微软雅黑 UI / 微软雅黑 / Segoe UI / 宋体 / 思源黑体；
- 编辑器字体：Cascadia Mono / Consolas / Courier New / 微软雅黑；
- 都存 `meta` 表（`ui_font` / `editor_font`），换库不影响；不打包字体，不增加体积。

## 5. 未包含

- **界面语言（中/英）**：需要逐条替换 200+ 处硬编码文案并补 i18n 机制，
  本版未做；建议单独作为 2.6 的完整迭代（先抽 `L10n`，再逐屏翻译、加回归）。
  当前界面仍为中文。

## 6. 验证

- `flutter analyze` 0 issue；`flutter test` **251 passed**（新增 7：分段、公式渲染、Mermaid 卡片、
  符号插入 ×3、符号面板）；
- release 构建与冒烟通过；
- 新增 `lib/ui/markdown_extras.dart`、`lib/ui/symbol_palette.dart`、`test/markdown_extras_test.dart`、
  `test/symbol_palette_test.dart`；文档 `docs/markdown.md`。
