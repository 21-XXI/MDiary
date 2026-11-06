# 本地模型实测：qwen3:8b / bge-m3

测量时间：2026-11-06　｜　工具：`scripts/bench-ollama.ps1`　｜　Ollama 0.40.14

## 环境

| 项 | 值 |
|---|---|
| CPU | Intel Core i7-9750H（6 核 12 线程，2.6 GHz） |
| 内存 | 15.8 GB |
| GPU | NVIDIA GeForce GTX 1660 Ti Max-Q，**6 GB 显存**，驱动 581.83 |
| 系统 | Windows（x64） |
| 模型 | `qwen3:8b`（5.2 GB，Q4）、`bge-m3`（1.2 GB） |

## 结论（TL;DR）

- **qwen3:8b 在这台机器上是「能用但不快」**：热态约 **10.5 tok/s**，输出 256 token 约 **25 秒**，
  首 token **0.8 秒**（冷启动时 4.3 秒）。
  6 GB 显存装不下 8B + 上下文，Ollama 采用 **30% CPU / 70% GPU** 混合推理（`ollama ps` 显示），
  显存占用 4.5 GB / 6 GB。
- **bge-m3 很轻松**：100% GPU、689 MB，300 字左右的切片热态约 **5.5 条/秒**；
  1000 个切片建索引约 3 分钟。
- 适合：**后台批量**（每日摘要、日报、soul.md）——每次几十秒；
  不太适合：高频交互式长回答（2.0.2 问答会偏慢）。

## 推理：qwen3:8b

| 指标 | 实测 |
|---|---|
| 模型加载 | 首次 61.3 s；已缓存后 9 s |
| 输出速度（9 次，3 轮 × 3 任务） | 9.88 – 10.92 tok/s，平均 **10.5 tok/s** |
| 单次 256 token 总耗时 | 24.1 – 26.6 s，平均 **25.1 s** |
| 首 token（TTFT） | **0.81 s**（热）/ 4.26 s（冷） |
| 显存占用 | 4491 MiB / 6144 MiB |
| 运行分配 | **30% CPU + 70% GPU**，上下文 4096，`llamacpp` |
| 预填充 | 42 tok/s（提示词很短，启动开销占比大，仅供参考） |

任务用的是中文日记场景：总结、改写成待办、写一段日记。

## Embedding：bge-m3

| 场景 | 实测 |
|---|---|
| 运行分配 | 100% GPU，689 MB，上下文 4096 |
| 冷启动（含加载，8 条短句） | 31.7 s |
| 热态，8 条短句 | **0.16 s ≈ 50 条/秒** |
| 热态，8 条 × 300 字 | **1.45 s ≈ 5.5 条/秒** |
| 单条 300 字 | 0.15 s |
| 维度 | 1024 |

> 注意：脚本里第一次 embedding 会包含模型加载，数字会很难看（0.25 条/秒）；
> 上表的热态数字是加载完成后再测的。

## 对 MDiary 的实际影响

| 场景 | 估算 |
|---|---|
| 每日增量摘要（2.0.4） | 20 篇 × 约 80 token ≈ 8 s/篇 → **2–3 分钟后台** |
| 每日日报（2.0.5） | 约 300 token → **约 30 秒/天** |
| soul.md（2.0.6） | 一次约 600 token → **约 1 分钟** |
| 首次全量索引（2.0.1） | 1000 个 300 字切片 → embedding 约 **3 分钟**（另加切片/写库） |
| 问答生成（2.0.2，待做） | TTFT ~1 s，200 token 答案 → **约 20 秒**，适合「问一句等一会」 |

## 调优建议

1. **交互用 4B、批处理用 8B**：`qwen3:4b` 预计能到 20–25 tok/s，问答体验会好很多；
   每日摘要/日报/soul 继续用 8B（后台跑，慢一点没关系）。
2. **缩小上下文**：把 `num_ctx` 从 4096 降到 2048，能让更多层留在 GPU，
   在 6 GB 卡上通常能明显提升 tok/s。
3. **限制输出长度**：`num_predict` 从 256 降到 128–160，单次时间直接减半（摘要类任务足够）。
4. **embedding 批大小**：RAG 索引已经是 32 条/批；300 字切片下约 5.5 条/秒，不要一次塞几百条。
5. 如果以后换 12 GB 以上的卡，8B 可以全量放显存，预期能到 20–30 tok/s。

## 复现

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1
powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1 -Model qwen3:4b -Runs 5
powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1 -SkipEmbed
```

结果 JSON 写在仓库根目录的 `bench-ollama.json`（已 gitignore）。

## 已知偏差

- TTFT 用流式首行分片计算，比真实首字略早；
- 首次调用包含模型加载，脚本单独记录 `load_seconds`，对比时要看第二次之后的数字；
- 机器同时开着 DSH 等进程，tok/s 会有 ±5% 波动。
