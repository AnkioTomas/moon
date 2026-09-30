#!/usr/bin/env python3
"""从主题图标字体提取可用图标名，生成 book.koplugin/ui/themes/widgets/icon/names.lua。

用法：python3 tools/build_icon_names.py

Material Symbols 靠 GSUB 连字把 ASCII 名字合成字形；同一字形常有多个别名，
这里每个字形只留一个名字（优先与字形名一致的那个），按字母序输出。
换字体文件后重跑。依赖 fontTools（pip install fonttools）。
"""

import os

from fontTools.ttLib import TTFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "book.koplugin", "ui", "themes", "widgets", "icon")
FONT = os.path.join(ICON_DIR, "MaterialSymbolsOutlined-Regular.ttf")
OUT = os.path.join(ICON_DIR, "names.lua")
PER_LINE = 6


def ligatures(font):
    chars = {glyph: chr(code) for code, glyph in font.getBestCmap().items()}
    for lookup in font["GSUB"].table.LookupList.Lookup:
        for sub in lookup.SubTable:
            if lookup.LookupType == 7:
                sub = sub.ExtSubTable
            for first, ligs in getattr(sub, "ligatures", {}).items():
                for lig in ligs:
                    parts = [first] + list(lig.Component)
                    if all(p in chars for p in parts):
                        yield "".join(chars[p] for p in parts), lig.LigGlyph


def main():
    by_glyph = {}
    for name, glyph in ligatures(TTFont(FONT)):
        by_glyph.setdefault(glyph, set()).add(name)
    names = []
    for glyph, aliases in by_glyph.items():
        canonical = glyph.lstrip("_")
        names.append(canonical if canonical in aliases else min(aliases))
    names.sort()
    lines = [
        "-- 由 tools/build_icon_names.py 从 MaterialSymbolsOutlined-Regular.ttf 生成，勿手改。",
        "return {",
    ]
    for i in range(0, len(names), PER_LINE):
        lines.append("    " + " ".join('"%s",' % n for n in names[i:i + PER_LINE]))
    lines.append("}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("%d icons -> %s" % (len(names), os.path.relpath(OUT, ROOT)))


if __name__ == "__main__":
    main()
