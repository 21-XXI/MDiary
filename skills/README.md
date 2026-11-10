# skills

两个内置 skill，均为标准 `SKILL.md` 结构，可单独安装到 agent：

| 目录 | 用途 |
|---|---|
| `diary-segmenter/` | 把资料切分成「一天一个主文件 + 附加笔记」的可导入目录 |
| `diary-distiller/` | 把日记库（主文件 + 附加笔记 + soul）蒸馏成可加载的 skill |

维护约定：应用内的蒸馏提示词（`lib/rag/skill_job.dart`）必须与 `diary-distiller/SKILL.md`
的六节结构与「资料分层 / 来源标注」规则保持一致，改一处要同步改另一处并跑测试。