# MDiary — 跨平台 .md 日记程序

v1.0 目标平台：**Windows 10/11 x64**（后续 v2.0 移植 Android/iOS/macOS/Linux）。

日记以 Markdown 明文保存，本地 SQLite 为唯一真源，附件按内容哈希去重存放，可随时导出为
通用的 `.md` 目录，不被任何厂商锁定。

## 功能（v1.0）

- Markdown 编辑 + 实时预览（分栏 / 纯预览切换），自动保存，异常退出不丢稿
- 时间轴列表、置顶、软删除与回收站
- 左栏月历：点某天即打开/新建那天的日记，有日记的日期带小圆点，默认停在最新一天
- 标签：编辑器里给日记打标签，列表角标可见，搜索框能按标签搜；导出写进 front matter
- 多库：一个目录 = 一个库（不同用户的库），可切换/新建/导入新库，也能按 id 合并两个库（附件按内容去重）
- 星图：把日记与它索引的附件画成星空，按全部 / 年 / 月 / 周浏览，点星即查看编辑
- 附件按内容哈希去重：同一张图被多篇日记引用也只存一份；导出时每篇 `.md` 都带着它
- 附件字节存进 SQLite（`attachment_blobs`，单文件 ≤ 100 MB），磁盘目录只是可重建的缓存
- 附件名写进正文（`![西湖.png](assets/<sha>.png)`），预览里渲染成彩色标签，点一下用系统默认程序打开
- 拖拽导入附件（Windows 桌面：从资源管理器把文件拖进窗口即可）
- 粘贴截图（Windows：工具栏按钮或 Ctrl+Shift+V，剪贴板里的图直接变成附件）
- 全文搜索（标题 / 正文 / 标签，中文子串匹配）
- 附件：任意文件（单文件 ≤ 100 MB），图片可在预览中直接显示，其余调用系统默认程序打开
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
flutter test                    # 单测（含真实 SQLite 集成测试）
```

打包用仓库根的脚本（见下），不要直接在中文路径下 `flutter build`：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1          # 增量构建
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Clean   # 清理后全量构建
```

> **为什么需要脚本**：Flutter 的 Windows 构建链（CMake → MSBuild）会把含中文的工程路径按
> ANSI(GBK) 转码，出现 `Unable to read file ...\app.dill` 构建失败。脚本在仓库路径含非 ASCII
> 字符时自动创建 ASCII 目录联接 `C:\mdiary_build` 并从那里构建，仓库位置与 Git 历史不受影响。

产物：`apps/client_flutter/build/windows/x64/runner/Release/mdiary.exe`（整个 `Release` 目录一起分发）。

`scripts/verify.ps1` 一次性跑完 analyze + test + build。

## 数据位置

| 内容 | 路径 |
|---|---|
| 数据库 | `<exe 目录>\MDiaryData\db\mdiary.sqlite`（默认库；设置里可换到任意目录） |
| 库列表 | `<exe 目录>\MDiaryData\libraries.json`（当前库 + 最近用过的库） |
| 附件缓存 | `<exe 目录>\MDiaryData\attachments\<sha256前两位>\<sha256>.<ext>`（字节在库里，删了会自动重建） |
| 错误日志 | `<exe 目录>\MDiaryData\logs\error.log`（发生异常时才创建，超过 1 MB 轮转为 `error.log.old`） |
| 位置记忆 | `<exe 目录>\mdiary-location.txt`（设置页改过数据目录后才出现） |
| 环境变量覆盖 | `MDIARY_HOME`（实际数据目录为 `%MDIARY_HOME%\MDiary`，测试/CI 用） |

**默认就地存放（绿色版）**：首次启动在 `mdiary.exe` 同目录建 `MDiaryData\`，数据库、附件、日志都在里面；
连同 exe 整个目录拷走即可搬家。exe 目录不可写（放在 `Program Files` 等）时依次退到
`%APPDATA%\MDiary`、系统临时目录，首页顶部会常驻提示实际使用的目录，设置页给出原因。

**更换数据目录**：设置 → 数据 → 「更改数据目录」，在资源管理器里选个文件夹即可。
程序会逐文件复制数据库与附件并校验大小，校验通过后切换到新目录、删除旧目录，
新位置记录在 `mdiary-location.txt`（重启后继续用新目录）；任何一步失败都会原地回滚，旧数据不动。

备份 = 复制整个数据目录，或使用「整库导出」得到纯 Markdown 副本。

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

提交后可用脚本核验最近若干条提交是否真的包含五段审查意见：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\check-commits.ps1 -Count 10
```

（实现上走 `git log --grep`，不用 PowerShell 读 `%B` —— PS 5.1 会按 GBK 解码导致中文匹配失败。）
