# diary-segmenter（MDiary 分词器 skill）

把用户上传的资料切分成按日期的日记，输出 MDiary 能直接导入的
`父文件夹/日期/当期.md` + 附件 结构。

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 给模型看的完整指令：切割规则、输出格式、写作要求、质检清单 |
| `references/import-format.md` | MDiary 导入格式说明（日期文件夹、front matter、附件） |
| `references/manifest.md` | `build_diary.py` 的 JSON 格式 |
| `scripts/build_diary.py` | 把结构化 JSON 落成目录树（纯标准库） |

## 用法

**方式一：把 SKILL.md 交给任意大模型**

1. 附上 `SKILL.md` 和用户资料；
2. 让模型输出 JSON（按 `references/manifest.md`）或直接输出文件树；
3. 用脚本落盘：

```bash
python scripts/build_diary.py --manifest diary.json --out ./MDiary导入
```

4. MDiary → 设置 → 从目录导入 .md，选 `./MDiary导入`。

**方式二：模型直接写文件**

如果 agent 有文件系统权限，按 `SKILL.md` 的目录结构直接写
`<out>/<YYYY-MM-DD>/当期.md`，附件放同目录即可。

## 验证

```bash
python scripts/build_diary.py --manifest examples/demo.json --out /tmp/demo --dry-run
```

应当看到每天一个目录、`当期.md`、附件复制提示；去掉 `--dry-run` 后可直接导入。
