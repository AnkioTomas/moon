#!/usr/bin/env python3
"""Optional local contact sheet from layout fixtures; requires Pillow and fonts."""
import json, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
FONT = ROOT / "koreader/resources/fonts/noto/NotoSansCJKsc-Regular.otf"
DEFAULT_IN = ROOT / "test/moon-bar-real-font-metrics.json"
DEFAULT_OUT = ROOT / "test/moon-bar-real-font-preview.png"

BG = (248, 248, 246)
BAND = (255, 255, 255)
INK = (30, 30, 30)
BAR_TRACK = (210, 222, 245)
BAR_FILL = (66, 133, 244)
LABEL = (90, 90, 90)
BORDER = (200, 200, 200)

def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_IN
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUT
    data = load(src)
    font_size = int(data.get("font_size") or 14)
    font = ImageFont.truetype(str(FONT), font_size)
    label_font = ImageFont.truetype(str(FONT), 12)
    cases = data["cases"]
    pad, gap_y, label_h = 16, 18, 20
    width = max(c["w"] for c in cases) + pad * 2
    height = pad
    for c in cases:
        height += label_h + c["h"] + gap_y
    height += pad
    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)
    y = pad
    for c in cases:
        title = f'{c["name"]}  {c["w"]}×{c["h"]}  gap={c["gap"]}  bar_h={c["bar_h"]}'
        draw.text((pad, y), title, font=label_font, fill=LABEL)
        y += label_h
        bx, by, bw, bh = pad, y, c["w"], c["h"]
        draw.rectangle([bx, by, bx + bw - 1, by + bh - 1], fill=BAND, outline=BORDER)
        bar = c.get("bar")
        if bar and bar.get("w", 0) > 0:
            x0 = bx + int(bar["x"])
            y0 = by + int(bar["y"])
            w = int(bar["w"])
            h = int(bar.get("h") or c["bar_h"] or 8)
            draw.rounded_rectangle([x0, y0, x0 + w - 1, y0 + h - 1], radius=min(4, h // 2), fill=BAR_TRACK)
            fill_w = max(1, int(w * 0.42))
            draw.rounded_rectangle([x0, y0, x0 + fill_w - 1, y0 + h - 1], radius=min(4, h // 2), fill=BAR_FILL)
        for t in c.get("texts") or []:
            tx = bx + int(t["x"])
            ty = by + int(t["y"])
            tw = int(t["w"])
            th = int(t.get("h") or 10)
            draw.text((tx, ty), t["text"], font=font, fill=INK)
            # 边框标出布局占位；这里不模拟 KOReader 的省略号与裁剪。
            draw.rectangle([tx, ty, tx + tw - 1, ty + th - 1], outline=(180, 180, 180))
        y += bh + gap_y
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(out)

if __name__ == "__main__":
    main()
