#!/usr/bin/env python3
"""Optional local font measurement (requires Pillow and a KOReader source tree)."""
import json, sys
from pathlib import Path
from PIL import ImageFont

ROOT = Path(__file__).resolve().parents[3]
FONT = ROOT / "koreader/resources/fonts/noto/NotoSansCJKsc-Regular.otf"

def width(font, text):
    box = font.getbbox(text)
    return int(box[2] - box[0])

def main():
    size = int(sys.argv[1]) if len(sys.argv) > 1 else 14
    font = ImageFont.truetype(str(FONT), size)
    texts = [line.rstrip("\n") for line in sys.stdin]
    out = {t: width(font, t) for t in texts}
    json.dump({"size": size, "font": str(FONT), "widths": out}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")

if __name__ == "__main__":
    main()
