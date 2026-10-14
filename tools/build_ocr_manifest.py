#!/usr/bin/env python3
"""下载 Tesseract tessdata_fast 识别模型并生成 assets/ocr/manifest.json。

用法：python3 tools/build_ocr_manifest.py [--fetch] [--out-dir assets/ocr]

不带 --fetch 时只为已有的 <id>.traineddata 重算 size / sha256；带 --fetch 先从上游
（raw.githubusercontent.com，失败回退 jsDelivr）下载。模型为 LSTM fast 版，兼容
KOReader 内置的 Tesseract 4.x / 5.x。只依赖 Python 标准库。

数据来源：https://github.com/tesseract-ocr/tessdata_fast （Apache-2.0）
"""

import argparse
import hashlib
import json
import os
import urllib.request

SOURCES = [
    "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/{id}.traineddata",
    "https://cdn.jsdelivr.net/gh/tesseract-ocr/tessdata_fast@main/{id}.traineddata",
]

# id 是 Tesseract 语言码（即 traineddata 文件名），name 是下载页显示名。
MODELS = [
    {"id": "chi_sim", "name": "简体中文"},
    {"id": "chi_tra", "name": "繁体中文"},
    {"id": "eng", "name": "英语"},
    {"id": "jpn", "name": "日语"},
    {"id": "chi_sim_vert", "name": "简体中文（竖排）"},
    {"id": "chi_tra_vert", "name": "繁体中文（竖排）"},
]


def fetch(model_id, path):
    last = None
    for tpl in SOURCES:
        url = tpl.format(id=model_id)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "moon-ocr-builder/1.0"})
            with urllib.request.urlopen(req, timeout=120) as res, open(path + ".tmp", "wb") as out:
                while True:
                    chunk = res.read(256 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
            os.replace(path + ".tmp", path)
            return
        except Exception as err:  # 换下一个源
            last = err
    raise SystemExit("download failed: %s (%s)" % (model_id, last))


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(256 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--out-dir", default="assets/ocr")
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    models = []
    for model in MODELS:
        path = os.path.join(args.out_dir, model["id"] + ".traineddata")
        if args.fetch or not os.path.exists(path):
            fetch(model["id"], path)
        models.append({
            "id": model["id"],
            "name": model["name"],
            "file": model["id"] + ".traineddata",
            "size": os.path.getsize(path),
            "sha256": digest(path),
        })
    manifest = {
        "version": 1,
        "variant": "tessdata_fast",
        "source": "https://github.com/tesseract-ocr/tessdata_fast",
        "license": "Apache-2.0",
        "models": models,
    }
    with open(os.path.join(args.out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote %d models" % len(models))


if __name__ == "__main__":
    main()
