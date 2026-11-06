# 蒸馏 skill（v2.2）

> 把 `soul.md` + RAG 索引语料交给**云端大模型**，蒸馏成一份其他模型可以直接加载的 skill。
> 每次生成新目录，**不覆盖**旧版本。

## 1. 入口与开关

- 导航栏 **✳ 蒸馏** 图标（在 RAG ✦ 左边），打开独立页面；
- 页面顶部开关「启用蒸馏」：关闭时不出请求、不生成；打开后才显示「立即蒸馏」；
- 蒸馏依赖云端模型：需先在 设置 → RAG 模型 里开启「使用云端模型」并填 API Key，
  否则按钮置灰并提示原因；
- 开关状态存在 `<数据目录>/settings.json` 的 `skill_enabled`（全局，不随库切换）。

## 2. 产物

```
<库目录>/db/skill/
  20261106-173012/
    SKILL.md      # 蒸馏结果（带 YAML front matter）
    meta.json     # 生成时间、模型、字节数、soul 大小、篇数、样本数、标签数
  20261106-175045/  # 下一次生成，从不覆盖
```

`SKILL.md` 开头是 front matter：

```yaml
---
generated_by: MDiary
model: cloud:gpt-4o-mini
created_at: 2026-11-06T17:30:12
source: soul.md + rag/index.sqlite
soul_bytes: 5120
---
```

正文结构（由云端模型按提示词生成）：`# Skill: …` / 何时使用 / 这个人的画像 / 常用事实与偏好 /
检索与回答规则 / 禁止事项；总长 ≤ 16 KB（超出按行截断并注明）。

## 3. 输入是什么

| 输入 | 说明 |
|---|---|
| `rag/soul.md` | 灵魂档案（≤8 KB）；缺失时先自动生成一次 |
| 语料摘要 | 最近 80 篇的 `entry_summary`（没有摘要就用正文首行），每条截断 90 字 |
| 标签与统计 | 总篇数、标签词表（前 20） |

**不会**把图片/附件原文上传；附件只出现在语料摘要的上下文里。

## 4. 提示词要点

- 只依据材料，不编造日期/金额/人名，不确定写「不确定」；
- 固定六段结构，便于其他模型解析；
- 回答规则要求先检索、带 `[日期-标题]` 引用；
- 禁止事项包含「不要编造」「不要发到未授权服务」。

## 5. 代码与测试

| 文件 | 作用 |
|---|---|
| `lib/rag/skill_job.dart` | `SkillJob`（读 soul + 摘要、调 distiller、写目录/meta）、`CloudSkillDistiller`、`FakeSkillDistiller` |
| `lib/rag/cloud_client.dart` | `CloudCompleter`（通用云端补全） |
| `lib/features/skill_page.dart` | 蒸馏页（开关、生成、列表、预览/复制） |
| `test/skill_job_test.dart` | 生成落盘/不覆盖/同秒去重/缺 soul 报错/16 KB 截断（5 例） |
| `test/rag_answer_test.dart` | 开关持久化 + 生成后出现在列表 |
| `test/rag_ui_test.dart` | 导航 → 开关 → 生成 → 列表 |

## 6. 已知限制

- 必须联网（云端）；本地模型不参与蒸馏；
- 每次都是全量蒸馏（不做增量 diff）；
- `db/skill/` 不自动清理，旧版本会一直保留（这是"不覆盖"的代价，需要手动删）；
- 蒸馏结果质量取决于云端模型与语料摘要质量；没有摘要的旧日记只能靠正文首行。
