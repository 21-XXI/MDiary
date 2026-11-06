# MDiary v2.3.0 发布说明（Windows x64）

发布日期：2026-11-06　｜　版本：`2.3.0+7`　｜　基于 v2.2.0

## 1. 导入格式：`父文件夹/日期/当期.md` + 附件

现在可以直接导入这种结构：

```
我的日记/
  2026-11-06/
    当期.md        # 文件名随意
    西湖.png
    发票.pdf
  2026-11-07/
    当期.md
```

规则：

- **日期文件夹**支持 `2026-11-06` / `2026.11.06` / `2026_11_06` / `2026年11月6日` / `20261106`，
  没有 front matter 时用文件夹名作日期（优先于文件修改时间）；
- 正文引用的附件按原逻辑复制进库，引用改写成 `assets/<sha>.<ext>`；
- **日期文件夹里没被引用的文件**也会作为附件导入，并在正文末尾追加 `## 附件` 列表；
- 只导入目录内部的文件；单附件上限 100 MB；重复导入（同日期 + 同正文）会跳过；
- 普通目录（非日期文件夹）保持旧行为：只导入正文引用到的附件。

## 2. 新增 skill：`diary-segmenter`（分词器）

`skills/diary-segmenter/`：把用户上传的散乱资料切成按日期的日记，输出上面的目录结构。

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 切分规则、输出格式、写作要求、质检清单（可直接喂给任意大模型） |
| `references/import-format.md` | 导入格式说明 |
| `references/manifest.md` | JSON 结构 |
| `scripts/build_diary.py` | 把结构化 JSON 落成目录树（纯标准库，支持 dry-run） |
| `examples/demo.json` | 示例 |

用法：

```bash
python scripts/build_diary.py --manifest diary.json --out ./MDiary导入
```

然后把 `./MDiary导入` 选进「设置 → 从目录导入 .md」。

## 3. 验证

- `flutter analyze` 0 issue、`flutter test` 239 passed（新增 3：日期文件夹/附件收集/旧行为回归）、
  release 构建与冒烟通过；
- 脚本实测：2 天示例生成 2 个日期目录、`当期.md` 与 2 个附件，front matter 正确。
