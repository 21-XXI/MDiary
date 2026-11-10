# MDiary v2.5.1 发布说明（Windows x64）

发布日期：2026-11-10　｜　版本：`2.5.1+11`　｜　基于 v2.5.0

## 1. 表情短代码

正文写 `:smile:`、`:heart:`、`:微笑:`，预览显示为 😄 ❤️：

- 内置约 90 个常用短代码（英文 + 常用中文别名）；
- 编辑器工具栏新增「表情」按钮：面板里可搜索、点选，插入 `:code: `；
- **可覆盖、可新增**：面板 →「自定义」填短代码 + 显示内容，自定义优先于内置；
  删除自定义后恢复内置值；
- 映射存 meta 表 `emoji_custom`（JSON），换库不影响、不需要联网；
- 围栏代码块与行内代码里的 `:smile:` 不会被替换。

## 2. 技术实现

| 文件 | 作用 |
|---|---|
| `lib/core/emoji.dart` | 内置映射表 + `applyEmoji`（跳过代码块/行内代码） |
| `lib/ui/emoji_picker.dart` | 搜索、网格选择、自定义增删 |
| `lib/state/app_state.dart` | `emojiMap`（内置+自定义）、`setEmoji` / `removeEmoji`，meta 持久化 |
| `lib/ui/markdown_view.dart` | 新增 `emoji` 参数，渲染前替换 |

## 3. 验证

- `flutter analyze` 0 issue；`flutter test` **258 passed**（新增 7：替换、代码块跳过、
  自定义优先、持久化、面板选择）；
- release 构建与冒烟通过；
- 新包 `MDiary-2.5.1-windows-x64.zip`。

## 4. 后续

- 表情包后续可扩：GIF/图片表情（映射到附件路径）、按主题分组的表情包、
  导入导出映射表；
- 仍未做：界面中英文（2.6 专项）、Mermaid 真渲染（需 WebView2 构建环境）。
