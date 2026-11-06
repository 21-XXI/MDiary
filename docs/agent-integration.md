# 把 MDiary 的 skill 接到 agent（DSH / Claude / 其他）

MDiary 产出两类 skill：

| 类型 | 位置 | 内容 |
|---|---|---|
| 内置 skill | `skills/diary-segmenter/` | 把资料切成日记（SKILL.md + references + scripts） |
| 蒸馏 skill | `<库目录>/db/skill/<时间>/SKILL.md` | 云端大模型按你的 soul.md + 语料生成的"这个人"档案 |

两类都是标准 `SKILL.md` 结构，**可以直接装进任何支持 skill 目录的 agent**。
DSH 的目录约定是 `%USERPROFILE%\.dsh\skills\<name>\SKILL.md`，front matter 必须含 `name` 和 `description`。

## 1. 装成 DSH 的 skill（已接通）

```powershell
# 内置分词器
powershell -ExecutionPolicy Bypass -File scripts\install-skill.ps1 -Source skills\diary-segmenter

# 蒸馏出来的某一份（把目录换成实际的）
powershell -ExecutionPolicy Bypass -File scripts\install-skill.ps1 -Source "C:\...\MDiaryData\db\skill\20261106-173012"
```

脚本会校验 front matter，然后把整个目录复制到 `%USERPROFILE%\.dsh\skills\<name>`。
装好后 agent 的 skill 目录里会多出对应条目（DSH 会热更新，见本次安装后的 catalog）。

**注意**：蒸馏 skill 的 `name` 是 `mdiary-skill-<时间>`，每次蒸馏都是新名字，
旧版本不会被覆盖；不想要旧版本时手动删 `~/.dsh/skills/mdiary-skill-*`。

## 2. skill 与工具的分工

skill 只是**说明书**（告诉 agent 怎么切分、怎么写、输出什么格式），它不能直接读你的日记。
要让 agent 真正查日记，需要"工具"层：

| 能力 | 现状 | 形态 |
|---|---|---|
| 混合检索日记 | ✅ 已实现 | `dart run tool/rag_search.dart --root <库> "查询" --json` |
| 取单篇 / 附件 | ✅（`get_entry` 待封装） | SQLite 直读 |
| 日报 / soul / skill | ✅ | `tool/rag_report.dart`、`tool/rag_soul.dart` |
| MCP server | 未实现（2.4 候选） | 计划：`mdiary mcp` 暴露 `search_diary` / `get_entry` / `get_soul` / `get_daily_report` |

在 MCP 做好之前，agent 可以这样用：

```powershell
# 让 agent 先检索，再回答
dart run tool/rag_search.dart --root "C:\...\MDiaryData" "去年在杭州吃了什么" --json
```

或把 `tool/` 目录里的 CLI 包装成 agent 的 shell 工具。

## 3. 接 Claude Skills / 其他 agent

- **Claude Code / Claude Desktop（Skills）**：同样把目录放到对应 skills 目录，`SKILL.md` 的
  `name` + `description` 就是 catalog 里显示的条目；
- **OpenAI 助手 / 自建 agent**：把 `SKILL.md` 当 system prompt 的一段，或把
  `references/*.md` 拆成检索片段；
- **任意聊天模型**：直接把 `SKILL.md` 贴进对话，要求"按这个 skill 处理我上传的资料"。

## 4. 蒸馏 skill 的特别说明

蒸馏出来的 `SKILL.md` 现在也带 `name` + `description`：

```yaml
---
name: mdiary-skill-20261106-173012
description: "根据日记库蒸馏出的 skill……"
model: cloud:gpt-4o-mini
created_at: 2026-11-06T17:30:12
source: soul.md + rag/index.sqlite
---
```

所以它既能给别的模型当上下文，也能直接作为 DSH 的 skill 安装。

## 5. 隐私边界

- skill 文件本身是**本地文本**，不含附件原文；
- 蒸馏时摘要会发到云端（见 2.0.3 的云端开关与 DPAPI 加密 Key）；
- 安装到 agent 只复制文本，不上传任何内容；
- `db/skill/` 只增不减，定期清理旧版本。
