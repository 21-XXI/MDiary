# 美术资源清单（v2.1.0）

> 用途：改 UI / 换品牌时的替换清单。当前**没有任何自有美术资源**：唯一的图片是 Flutter 默认图标，
> 界面里的图形全部是 Material 图标，没有自定义字体、没有位图插图。

## 1. 位图 / 图标文件

| # | 资源 | 路径 | 规格 | 用在哪 | 现状 |
|---|---|---|---|---|---|
| A1 | 应用图标 | `apps/client_flutter/windows/runner/resources/app_icon.ico` | 33 KB，内含 16/32/48/256 四种尺寸 | exe 文件图标、窗口标题栏、任务栏、Alt-Tab、资源管理器 | **Flutter 默认蓝色 logo**，非自有品牌 |
| A2 | 界面插图 / logo | —— | —— | —— | **没有**（App 内没有 logo，只有文字与 Material 图标） |
| A3 | 字体文件 | —— | —— | —— | **没有**（全部用系统字体） |
| A4 | 启动闪屏 | —— | —— | —— | 没有（Windows 直接进主界面） |

## 2. 界面图标（58 个 Material 图标，全部来自代码 `Icons.xxx`）

| 区域 | 图标 |
|---|---|
| 导航 / 头部 | `hub_outlined`（星图）、`auto_awesome_outlined`（RAG）、`delete_outline`（回收站）、`settings_outlined`（设置）、`auto_awesome`、`add` |
| 编辑器 | `save_outlined`、`visibility_outlined`、`vertical_split_outlined`、`attach_file`、`image_outlined`、`push_pin`、`push_pin_outlined`、`more_horiz`、`edit_note`、`edit_outlined` |
| 列表 / 搜索 | `search`、`search_off`、`close`、`history`、`sell_outlined`、`menu_book_outlined`、`sort`、`circle_outlined`、`chevron_left`、`chevron_right` |
| 回收站 | `delete_outline`、`delete_forever`、`delete_sweep_outlined`、`restore`、`cleaning_services_outlined` |
| 星图 | `hub_outlined` |
| RAG | `psychology_outlined`、`description_outlined`、`event_note_outlined`、`storage`、`storage_outlined`、`refresh`、`copy`、`playlist_add_check`、`today`、`cloud_upload_outlined`、`link_off` |
| 设置 | `backup_outlined`、`compress`、`folder_outlined`、`folder_open`、`open_in_new`、`swap_horiz`、`library_add_outlined`、`merge_type`、`delete_outline`、`add_photo_alternate_outlined` |
| 状态 / 提示 | `warning_amber_rounded`、`error_outline`、`info_outline`、`check_circle_outline`、`file_upload_outlined`、`file_download_outlined`、`attachment` |

替换方式有两种：
1. **换图标引用**（改代码）：把 `Icons.x` 换成另一套 Material 图标，或换成自定义 SVG/PNG；
2. **换图标字体**（不推荐混用）：引入第三方图标字体，需要改 `pubspec.yaml` 的 `fonts:`。

## 3. 颜色与主题

| 项 | 值 | 位置 |
|---|---|---|
| 主色种子 | `#4C6A92`（灰蓝） | `lib/core/theme.dart` `AppTheme.seed` |
| 配色方案 | Material 3 `ColorScheme.fromSeed`（浅色 / 深色各一套） | 同上 |
| 启动失败页底色 | `#F2F2F2` | `lib/main.dart` 兜底主题 |
| 编辑器正文 | 等宽字体 + `height 1.6`，字号 12–28 可调 | `AppTheme.editorStyle` |

## 4. 字体

| 用途 | 当前 | 说明 |
|---|---|---|
| 界面 | 系统字体回落链：`Microsoft YaHei UI` → `Microsoft YaHei` → `Segoe UI` → `Noto Sans CJK SC` | 没有打包字体 |
| 编辑器 | `Cascadia Mono` → `Consolas` → `Microsoft YaHei UI` → `Menlo` | 等宽显示 Markdown |
| 预览正文 | `Cascadia Mono` + `Consolas`/`Microsoft YaHei` | `lib/ui/markdown_view.dart` |

## 5. 品牌 / 标识文字（硬编码）

| # | 文案 | 位置 | 备注 |
|---|---|---|---|
| B1 | 窗口标题 `MDiary` | `windows/runner/main.cpp` `window.Create(L"MDiary", …)` | 改这里同时要改 `FindWindowW(L"MDiary")` 与互斥名 `Global\MDiary.SingleInstance` |
| B2 | `MaterialApp(title: 'MDiary')` | `lib/app.dart` | 仅 Windows 任务栏/系统显示用 |
| B3 | 版本号 `MDiary v2.1.0` | `lib/features/settings_page.dart`（关于） | 与 `pubspec.yaml` 的 `version:` 手动同步 |
| B4 | 启动失败页 `MDiary 启动失败` | `lib/main.dart` | |
| B5 | exe 元数据：`CompanyName com.mdiary`、`FileDescription / InternalName / ProductName MDiary`、`OriginalFilename mdiary.exe`、版权 | `windows/runner/runner.rc` | 资源管理器「属性 → 详细信息」里可见 |
| B6 | 数据目录与文件名：`MDiaryData/`、`db/mdiary.sqlite`、`mdiary-location.txt`、`libraries.json`、`rag/`、`soul.md`、`mdiary.exe` | `lib/core/app_paths.dart`、`main.cpp`、打包脚本 | **改名会影响兼容**：老用户数据目录/指针文件找不到，需迁移逻辑 |
| B7 | 环境变量 `MDIARY_HOME`、方法通道 `mdiary/clipboard`、`mdiary/drop`、`mdiary/shell` | 多处 | 内部标识，一般不必改 |
| B8 | 界面文案（中文，约 200+ 条，全部硬编码在 `lib/features/*.dart`、`lib/ui/*.dart`） | 见文件 | 没有 i18n/arb；改文案是纯文本替换 |

## 6. 发布物料

| 项 | 现状 |
|---|---|
| 交付包 | `MDiary-2.1.0-windows-x64.zip`，图标随 exe |
| 文档 | README / 使用说明 / 发布说明 / 验收清单 / 交付说明，**纯文字，无配图** |
| 安装器 | 无（zip 绿色版），没有安装器图标/横幅 |
| 截图 | 仓库里没有产品截图 |

## 7. 建议的替换方案（供选择）

| 优先级 | 要换什么 | 需要你提供 | 我这边的工作 |
|---|---|---|---|
| P0 | 应用图标 | 一张 1024×1024 PNG（或 SVG），透明背景 | 生成多尺寸 `.ico` 覆盖 A1；可选加 exe 元数据里的产品名 |
| P1 | 主色 | 一个十六进制主色（如 `#2F6F6B`） | 改 `AppTheme.seed`，深浅两套自动跟着变 |
| P2 | 界面图标风格 | 指定一套（继续 Material / 换成某套线性图标 / 单独给几个 SVG） | 逐个替换引用，涉及 58 个图标 |
| P3 | 界面字体 | 一个 `.ttf/.otf`（商用可授权） | 加 `pubspec` fonts + 主题 `fontFamily` |
| P4 | 品牌名 / 标识文字 | 新名字（中英文） | 改 B1–B5；B6 文件/目录改名需要迁移兼容，建议只改展示名 |
| P5 | 文档配图 / 截图 | 不需要提供，我可以截 | 生成 README 截图与交付说明配图 |

## 8. 注意

- **只改展示名**（窗口标题、关于页、exe 元数据）风险低；**改数据目录名/exe 名**会破坏老用户升级，
  需要额外的迁移逻辑，建议放到 v3.0 一起做。
- 图标替换不需要改 Flutter 资源；Windows 直接读 exe 里的 `.ico`。
- 若要在 App 内加 logo（现在没有），需要新增 `assets/branding/logo.png` + `pubspec.yaml` 的 `assets:`，
  并在首页头部加图片；这是新增资源，不是替换。
