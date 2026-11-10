# 提交审查记录 — 2026-11-10 统一模型管理（v2.7 第一步）

**范围**：模型配置（profile）+ 角色（role）注册表、设置页入口、问答/生成/向量按角色取模型
**对应需求**：用户「需要对现在所有用到的模型进行统一的管理」；按「角色 + 多套配置」实现

## 1. 改动

| 文件 | 说明 |
|---|---|
| `lib/rag/model_registry.dart`（新增） | `ModelRole`（chat/generate/segment/memory/embed）、`ModelProfile`、`ModelRegistry`（角色映射、增删、JSON）、`ModelRegistryStore`（`<数据目录>/models.json`）、`ModelRegistry.migration(RagSettings)` |
| `lib/state/app_state.dart` | 加载/迁移/保存注册表；`profileFor`、`upsertModelProfile`、`removeModelProfile`、`setRoleProfile`；`ragAnswerer`/`ragSummarizer`/向量 embedder 优先按角色取配置，未设置时回退旧设置；改配置会重置 RAG 连接 |
| `lib/features/settings_page.dart` | 新增「模型」区：配置列表（增/改/删）、五个角色下拉、云端 Key DPAPI 加密、说明文案 |
| `test/model_registry_test.dart`（5 例） | 迁移、JSON 往返、删除清角色、AppState 迁移落盘、角色与配置持久化 |
| `docs/models.md` | 结构、角色、迁移、安全边界 |

## 2. 设计决定

- **配置与角色分离**：同一模型可被多个角色复用，换模型只改角色；
- **平滑迁移**：首次启动从旧 `settings.json` 生成三套本地配置 + 可选云端；
- **回退策略**：角色未设置时仍走旧设置，避免升级后问答变哑；
- **向量固定本地**：embed 角色只接受 Ollama，云端配置不参与 embedding；
- **Key 不回显**：编辑时留空表示保持原密文。

## 3. 风险与遗留

| 级别 | 项 | 说明 |
|---|---|---|
| 中 | 两处设置并存 | 旧「RAG 模型」卡片仍保留（云端开关、Key、蒸馏开关），与「模型」区有重叠；下一步收拢 |
| 中 | 云端 Key 双写 | 旧 cloud 配置与模型配置各存一份密文，可能出现不一致 |
| 低 | 角色切换不校验可用性 | 选了一个没拉取的模型，问答时才报错；后续加「测试连接」 |
| 低 | 迁移只跑一次 | 若用户后来改了旧设置，注册表不会自动同步（设计如此，避免覆盖手工配置） |

## 4. 验证

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 issue |
| `flutter test` | **269 passed**（新增 5） |
| 覆盖 | 迁移、序列化、删除清引用、首次启动写盘、重启后角色保留 |

## 5. 回滚

`git revert`；`models.json` 为新增文件，回退后旧设置仍生效。
