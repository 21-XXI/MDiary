# 统一模型管理（v2.7 第一步）

> 所有模型的唯一入口：设置 → **模型**。配置（profile）与角色（role）分开，一个配置可被多个角色复用。

## 结构

```
<数据目录>/models.json
{
  "version": 1,
  "profiles": [
    {"id": "local-chat", "name": "本地 · 对话", "provider": "ollama",
     "base_url": "http://127.0.0.1:11434", "model": "qwen3:8b",
     "api_key": "", "temperature": 0.3, "num_ctx": 0}
  ],
  "roles": {"chat": "local-chat", "generate": "local-generate", "embed": "local-embed"}
}
```

## 角色

| 角色 | 默认用途 | 说明 |
|---|---|---|
| `chat` | RAG 问答、对话生成 | 可本地 / 云端 |
| `generate` | 摘要、日报、soul、蒸馏 | 可本地 / 云端 |
| `segment` | 分词切分（2.7 第二步） | 可本地 / 云端 |
| `memory` | 记忆对话（2.7 第三步） | 可本地 / 云端 |
| `embed` | 向量索引 | **仅本地 Ollama**（向量不出本机） |

角色未设置时，问答/生成/向量回退到旧的「RAG 模型」设置（settings.json），保证升级不炸。

## 迁移

首次启动如果没有 `models.json`：

- 用旧 `settings.json` 生成 `local-chat` / `local-generate` / `local-embed` 三套配置；
- 若旧设置开了云端，会再加一套 `cloud-generate`；
- 角色映射：chat→local-chat、generate/segment→local-generate、memory→local-chat、embed→local-embed。

## 界面

设置 → 模型：

- 配置列表（名称、模型、地址/云端），可添加 / 编辑 / 删除；
- 删除配置会自动清掉引用它的角色；
- 五个角色各一个下拉：未设置时走旧设置回退；
- 云端 Key 仍用 Windows DPAPI 加密后写 `api_key`。

## 安全与边界

- Key 只存密文；界面不回显已保存的 Key（留空=保持不变）；
- 云端配置需要用户显式选择，且仍受 2.0.3 的云端确认弹窗保护；
- 向量角色固定本地，避免把日记正文发到云端做 embedding。

## 后续

- 第二步：分词 agent（文件夹 → 预览 → 新建库导入），用 `segment` 角色；
- 第三步：记忆对话（只用蒸馏 skill），用 `memory` 角色；
- 第四步：agent 配置页（步数上限、工具权限、日志）。
