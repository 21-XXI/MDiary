# MDiary v2.3.1 发布说明（Windows x64）

发布日期：2026-11-06　｜　版本：`2.3.1+8`　｜　基于 v2.3.0

## 1. skill 可以直接接 agent 了

- 蒸馏出来的 `SKILL.md` front matter 增加 **`name`** 与 **`description`**：
  ```yaml
  name: mdiary-skill-20261106-173012
  description: "根据日记库蒸馏出的 skill……"
  ```
  这正是 DSH / Claude Skills 这类 agent 目录需要的字段；之前只有自定义元数据，装进去不显示；
- 新增 `scripts/install-skill.ps1`：校验 front matter → 复制到 `%USERPROFILE%\.dsh\skills\<name>`；
- 内置 `skills/diary-segmenter` 也补了 front matter，并且**已经装进本机 DSH**，
  agent 的 skill 目录里立即可见；
- 新增 `docs/agent-integration.md`：说明「skill（说明书） / CLI 工具 / MCP（2.4 候选）」三层怎么配合。

## 2. 用法

```powershell
# 内置 skill
powershell -ExecutionPolicy Bypass -File scripts\install-skill.ps1 -Source skills\diary-segmenter

# 蒸馏出的某一份
powershell -ExecutionPolicy Bypass -File scripts\install-skill.ps1 -Source "C:\...\MDiaryData\db\skill\20261106-173012"
```

装好后重启/刷新 agent，skill 目录会出现对应条目；蒸馏 skill 每次名字不同，旧版本不会覆盖。

## 3. 验证

- `flutter analyze` 0 issue；`flutter test` 239 passed；release 构建与冒烟通过；
- 实际安装验证：`~/.dsh/skills/diary-segmenter/` 下 6 个文件齐全，DSH 的 skill catalog 已出现
  `diary-segmenter`；
- 蒸馏 skill 的 front matter 由 `skill_job_test` 断言（name/description 必须存在）。
