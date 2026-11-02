# MDiary — 跨平台 .md 日记程序

v1.0 目标平台：**Windows 10/11 x64**（后续 v2.0 移植 Android/iOS/macOS/Linux）。

日记以 Markdown 明文保存，本地 SQLite 为唯一真源，附件按内容哈希去重存放，可随时导出为
通用的 `.md` 目录，不被任何厂商锁定。

## 功能（v1.0）

- Markdown 编辑 + 实时预览（分栏 / 纯预览切换），自动保存，异常退出不丢稿
- 时间轴列表、置顶、软删除与回收站
- 全文搜索（标题 / 正文，中文子串匹配）
- 附件：任意文件（单文件 ≤ 25 MB），图片可在预览中直接显示，其余调用系统默认程序打开
- 单篇导出 `.md`、整库导出（`.md` + `assets/`）、从目录导入 `.md`
- 主题（浅色/深色/跟随系统）、编辑字号

## 目录结构

```
MDiary/
  apps/client_flutter/     Flutter 客户端（v1.0 全部代码）
  docs/                    需求、架构、验收、提交审查记录
  scripts/                 启动/校验脚本
  .gitmessage              提交模板（改动/原因/风险/验证/回滚）
```

## 开发

前置：Flutter 3.47.x（Dart 3.13）、Visual Studio 2022 生成工具（C++ 桌面工作负载）。

```powershell
cd apps/client_flutter
flutter pub get
flutter run -d windows          # 调试运行
flutter analyze                 # 静态检查
flutter test                    # 单测
flutter build windows --release # 打包
```

产物：`apps/client_flutter/build/windows/x64/runner/Release/mdiary.exe`。

仓库根目录 `scripts/verify.ps1` 一次性跑完 analyze + test + build。

## 数据位置

| 内容 | 路径 |
|---|---|
| 数据库 | `%APPDATA%\MDiary\mdiary.sqlite` |
| 附件库 | `%APPDATA%\MDiary\attachments\<sha256前两位>\<sha256>.<ext>` |
| 崩溃日志 | `%APPDATA%\MDiary\logs\` |

备份 = 复制整个 `%APPDATA%\MDiary`，或使用「整库导出」得到纯 Markdown 副本。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `Ctrl+N` | 新建日记 |
| `Ctrl+S` | 立即保存 |
| `Ctrl+F` | 聚焦搜索框 |
| `Ctrl+P` | 切换预览 |
| `Esc` | 搜索框失焦 |

## 提交规范

每次提交必须先 `git diff --staged` 自审，并按 `.gitmessage` 填写审查意见；需要留档的审查记录写入
`docs/reviews/`。提交历史中每条 commit 都可以独立回滚。
