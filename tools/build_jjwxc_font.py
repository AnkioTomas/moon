#!/usr/bin/env python3
"""由一份晋江反爬字体 + 码点对照表生成 source/jjwxc/font_table.lua。

用法：tools/build_jjwxc_font.py <jjwxcfont_xxx.ttf> <对照表> [输出文件]
对照表每行 `<PUA 码点十六进制> <字>`，如 `E044 他`。字形哈希算法必须与
source/jjwxc/font.lua 的 Font.key 逐点一致（坐标按 1000 单位归一）。
"""
import math
import sys

from fontTools.ttLib import TTFont

M1, M2 = 2147483647, 1000000007


def key(font, name):
    glyf = font["glyf"]
    coords, ends, flags = glyf[name].getCoordinates(glyf)
    upm = font["head"].unitsPerEm
    h1 = h2 = 7
    seq = [len(ends)] + list(ends)
    for (x, y), f in zip(coords, flags):
        seq += [f & 1, math.floor(x * 1000 / upm + 0.5), math.floor(y * 1000 / upm + 0.5)]
    for v in seq:
        v += 100000
        h1 = (h1 * 131 + v) % M1
        h2 = (h2 * 137 + v) % M2
    return "%08x%08x" % (h1, h2)


def main():
    font = TTFont(sys.argv[1])
    cmap = font.getBestCmap()
    rows = {}
    for line in open(sys.argv[2], encoding="utf-8"):
        parts = line.split()
        if len(parts) == 2:
            rows[key(font, cmap[int(parts[0], 16)])] = parts[1]
    out = sys.argv[3] if len(sys.argv) > 3 else "book.koplugin/source/jjwxc/font_table.lua"
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("--[[--\n晋江 VIP 章反爬字体：字形哈希 → 真字。由 tools/build_jjwxc_font.py 生成，勿手改。\n\n")
        fh.write("@module koplugin.book.source.jjwxc.font_table\n--]]\n\nreturn {\n")
        for k in sorted(rows):
            fh.write('    ["%s"] = "%s",\n' % (k, rows[k]))
        fh.write("}\n")
    print(len(rows), "glyphs ->", out)


main()
