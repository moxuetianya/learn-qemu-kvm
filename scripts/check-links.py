#!/usr/bin/env python3
"""检查仓库内所有 markdown 文件的内部链接（相对路径）是否有效。

用法: python3 scripts/check-links.py [--root DIR]
退出码: 0 = 全部通过, 1 = 有坏链
"""
import argparse
import os
import re
import sys
import urllib.parse

LINK_RE = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
# 提取 ``` 代码块以便跳过
FENCE_RE = re.compile(r'```.*?```', re.DOTALL)


def check_file(md_path: str, root: str):
    broken = []
    try:
        text = open(md_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as e:
        return [(md_path, "<read error>", str(e))]

    # 去掉代码块（C 语言的 fn(x) 会被误判为链接）
    text_wo_code = FENCE_RE.sub("", text)

    for m in LINK_RE.finditer(text_wo_code):
        target = m.group(1).strip()
        if target.startswith(("http://", "https://", "#", "mailto:", "data:")):
            continue
        # 同页锚点
        if target.startswith("#"):
            continue
        path = urllib.parse.unquote(target.split("#")[0])
        if not path:
            continue
        abs_path = os.path.normpath(
            os.path.join(os.path.dirname(md_path), path))
        if not os.path.exists(abs_path):
            broken.append((os.path.relpath(md_path, root), target))
    return broken


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".", help="仓库根目录")
    args = ap.parse_args()

    md_files = []
    for base, dirs, files in os.walk(args.root):
        # refs/ 是上游 git subtree 镜像，保持原样不检查（上游自身存在坏链）
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "refs")]
        for f in files:
            if f.endswith(".md"):
                md_files.append(os.path.join(base, f))

    total_broken = []
    for mf in sorted(md_files):
        total_broken.extend(check_file(mf, args.root))

    print(f"检查了 {len(md_files)} 个 markdown 文件")
    if total_broken:
        print(f"❌ 发现 {len(total_broken)} 个坏链:")
        for f, t in total_broken:
            print(f"  {f}  ->  {t}")
        sys.exit(1)
    print("✅ 所有内部链接有效")


if __name__ == "__main__":
    main()
