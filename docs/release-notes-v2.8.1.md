# MDiary v2.8.1 发布说明（Windows x64）

发布日期：2026-11-10　｜　版本：`2.8.1+16`　｜　基于 v2.8.0

## 1. 附加笔记进 RAG
- 保存附加 md 后后台触发索引重建；
- 检索来源区分「主 / 附」前缀（回答引用仍是 [日期-标题]）。

## 2. 附加笔记 blob 清理
- 编辑/保存后自动删除未被引用的旧 blob。

## 3. 分词 notes 导入
- 分词 skill 输出的 `notes` 字段现在真正落地：写成 `notes/` 目录里的附加笔记；
- 导入后自动作为附件挂到当天主文件，并把 `notes/<文件名>` 重写为 `assets/<sha>.md`；
- 附件仍只读、按内容去重。

## 4. Skill 更新
- 分词：主文件 + 附加笔记拆分、notes 字段、外部 agent 输出完整库结构；
- 蒸馏：新增 `skills/mdiary-distiller/SKILL.md`，纳入附加笔记、资料分层、事实来源标注。

## 5. 验证
- `flutter analyze` 0 issue；`flutter test` 294 passed；
- 包 `MDiary-2.8.1-windows-x64.zip`。