# 提交审查记录 — 2026-11-06 v2.3.1 skill 接 agent（DSH）

**范围**：蒸馏 skill 增加 `name`/`description`、分词器 skill 补 front matter、`install-skill.ps1`、
`docs/agent-integration.md`、实际安装到本机 DSH；2.3.1 打包
**对应需求**：用户问「skill 怎么接像 DSH 这样的 agent」

## 1. 改动

| 文件 | 说明 |
|---|---|
| `lib/rag/skill_job.dart` | 蒸馏产物 front matter 增加 `name: mdiary-skill-<时间>`、`description`（从首段引用/首行提取，YAML 安全转义）；`meta.json` 同步 `name` |
| `skills/diary-segmenter/SKILL.md` | 补 YAML front matter（name/description），与蒸馏 skill 格式统一 |
| `scripts/install-skill.ps1`（新增） | 校验 front matter（`---`、`name`、`description`）→ 复制到 `~/.dsh/skills/<name>`，支持自定义 target |
| `docs/agent-integration.md`（新增） | 两类 skill 的安装方式、skill 与工具的分工、Claude/OpenAI 接法、隐私边界 |
| `test/skill_job_test.dart` | 增加 `name:` / `description:` 断言 |
| 文档 | README、project.md §10.8、release-notes-v2.3.1 |

## 2. 实测：DSH 已接通

- 执行 `scripts\install-skill.ps1 -Source skills\diary-segmenter`；
- `~/.dsh/skills/diary-segmenter/` 下 6 个文件齐全；
- **DSH 的 skill catalog 当场出现了 `diary-segmenter`**（无需重启），说明目录与 front matter 格式正确；
- 蒸馏 skill 走同一个脚本，`name` 为 `mdiary-skill-<时间>`，每次新名字、不覆盖。

## 3. 风险与遗留

| 级别 | 项 | 说明 |
|---|---|---|
| 中 | skill 只装在本机 | 安装脚本默认 `%USERPROFILE%\.dsh\skills`；换机器/换 agent 要重装 |
| 中 | 蒸馏 skill 膨胀 | 每次蒸馏一个新 `name`，装进 agent 后会不断累积；需要手动清理旧 `mdiary-skill-*` |
| 中 | 没有 MCP 工具 | skill 只是说明书；agent 想查日记仍需 CLI 或 2.4 的 MCP server |
| 低 | 非 DSH agent | Claude Skills 目录不同，脚本支持 `-Target` 覆盖；OpenAI 类只能贴 prompt |
| 低 | description 质量 | 从模型输出首段提取，模型没写引用时可能取到第一句正文，够用但不完美 |

## 4. 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 issue |
| `flutter test` | **239 passed** |
| `scripts/verify.ps1` | analyze + test + build + 冒烟 全通过 |
| 安装 | DSH catalog 出现 `diary-segmenter`（本条即证据） |
| 打包 | `MDiary-2.3.1-windows-x64.zip`（14,128,297 字节），SHA256 `f36c65a0…7a24`，包内含 `skills/` 与 `install-skill.ps1` |

## 5. 回滚

`git revert`；已安装到 `~/.dsh/skills/diary-segmenter` 的副本需手动删除（不属于仓库）。
