#!/usr/bin/env python3
"""把结构化 JSON 落成 MDiary 可导入的目录树。

用法：
    python build_diary.py --manifest diary.json --out ./MDiary导入
    python build_diary.py --manifest diary.json --out ./out --dry-run

manifest 格式（数组，按日期升序）：
[
  {
    "date": "2026-11-06",
    "title": "杭州出差第一天",
    "tags": ["旅行", "工作"],
    "body": "第一人称正文……",
    "attachments": ["C:/素材/西湖.png", "C:/素材/发票.pdf"]
  }
]

输出：
    <out>/2026-11-06/当期.md
    <out>/2026-11-06/西湖.png
"""
import argparse
import json
import shutil
import sys
from pathlib import Path


def load_manifest(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise SystemExit("manifest 必须是数组")
    return data


def validate(item, index):
    if not isinstance(item, dict):
        raise SystemExit(f"第 {index + 1} 条不是对象")
    date = item.get("date")
    if not isinstance(date, str) or len(date) != 10 or date[4] != "-" or date[7] != "-":
        raise SystemExit(f"第 {index + 1} 条 date 必须是 YYYY-MM-DD：{date!r}")
    body = item.get("body")
    if not isinstance(body, str) or not body.strip():
        raise SystemExit(f"{date} 的 body 为空")
    title = item.get("title") or date
    tags = item.get("tags") or []
    if not isinstance(tags, list):
        raise SystemExit(f"{date} 的 tags 必须是数组")
    return date, str(title).strip(), [str(tag).strip() for tag in tags if str(tag).strip()], body


def render(title, date, tags, body):
    lines = ["---", f"title: {title}", f"date: {date}", "tags: [" + ", ".join(tags) + "]", "---", "", body.strip(), ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="MDiary 日记目录生成器")
    parser.add_argument("--manifest", required=True, help="结构化 JSON 路径")
    parser.add_argument("--out", required=True, help="输出根目录")
    parser.add_argument("--dry-run", action="store_true", help="只打印，不写文件")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        raise SystemExit(f"找不到 manifest：{manifest_path}")
    entries = load_manifest(manifest_path)
    out_root = Path(args.out)

    written = 0
    for index, item in enumerate(entries):
        date, title, tags, body = validate(item, index)
        folder = out_root / date
        if not args.dry_run:
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "当期.md").write_text(render(title, date, tags, body), encoding="utf-8")
        print(f"[{date}] {title} -> {folder / '当期.md'}")

        for attachment in item.get("attachments") or []:
            source = Path(attachment)
            if not source.is_absolute() and not source.exists():
                source = manifest_path.parent / source
            if not source.exists():
                print(f"  ! 附件不存在，已跳过：{source}", file=sys.stderr)
                continue
            target = folder / source.name
            if args.dry_run:
                print(f"  附件：{source} -> {target}")
            else:
                shutil.copy2(source, target)
                print(f"  附件：{target.name}")
        written += 1

    print(f"\n共 {written} 天；{'（dry-run，未写文件）' if args.dry_run else f'输出目录：{out_root}'}")
    if not args.dry_run:
        print("接下来：MDiary → 设置 → 从目录导入 .md，选这个输出目录。")


if __name__ == "__main__":
    main()
