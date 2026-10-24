#!/usr/bin/env python3
"""生僻字注音的汉字拼音词库（assets/rare/zh-pinyin）补繁体字。

原词库只收《通用规范汉字表》的简体字与简体词组（rank = 字表序号，表外字 9000），繁体书里
時 / 尋 / 讀 / 無 这类字查不到、「全部」档也不注音。本脚本在已有词库上追加：

  - 繁体单字：OpenCC TSCharacters（繁 → 简）里简体字已在词库的繁体字；
    读音取 mozillazg/pinyin-data 该繁体字的首选读音（不照抄简体：乾 qián ≠ 干 gàn），
    pinyin-data 没有的退回简体字读音；rank 取对应简体字里最小的（繁体读者眼里 時 与 时 一样常见）。
  - 繁体词组：词库里的多字词组（多音字定音用，如 银行 háng）经 OpenCC STPhrases / STCharacters
    （简 → 繁，一对多取首选）转成繁体，和原词组不同且词库里没有时追加，读音与 rank 照抄。

  - 表外冷僻字：pinyin-data 有读音、词库里没有的 BMP 汉字（叕 龘 沝 秏…），rank 9000（最生僻档）。

已在词库里的键一律不动（脚本可重复运行，结果不变）。只用 Python 标准库；数据版本固定在下方常量。
输出：覆盖 lexicon.tsv.part.001 并重写 manifest.json（entries / sha256 / size / built_at）。

  python3 tools/build_rare_pinyin.py            # 联网拉 OpenCC 与 pinyin-data
  python3 tools/build_rare_pinyin.py --data DIR # 用 DIR 下已下载的同名文件（离线）
"""

import argparse
import datetime
import hashlib
import json
import os
import urllib.request

OPENCC = "https://raw.githubusercontent.com/BYVoid/OpenCC/ver.1.1.9/data/dictionary/"
PINYIN = "https://raw.githubusercontent.com/mozillazg/pinyin-data/v0.15.0/"
FILES = {
    "TSCharacters.txt": OPENCC,
    "STCharacters.txt": OPENCC,
    "STPhrases.txt": OPENCC,
    "pinyin.txt": PINYIN,
}
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "rare", "zh-pinyin")
PART = "lexicon.tsv.part.001"
OUT_OF_TABLE_RANK = 9000
NAME = "#name=汉字拼音（通用规范汉字表，含繁体）"
LICENSE = ("#license=MIT (mozillazg/pinyin-data, phrase-pinyin-data); 字序: 通用规范汉字表 "
           "(ben-hua/general_standard_chinese, Apache-2.0); 繁简对照: OpenCC (Apache-2.0)")


def load(name, data_dir):
    if data_dir:
        with open(os.path.join(data_dir, name), encoding="utf-8") as f:
            return f.read()
    req = urllib.request.Request(FILES[name] + name, headers={"User-Agent": "moon-rare-builder"})
    with urllib.request.urlopen(req, timeout=60) as res:
        return res.read().decode("utf-8")


def pairs(text):
    """OpenCC 词典：键 → 候选列表（首个为首选）。"""
    out = {}
    for line in text.splitlines():
        if not line or line.startswith("#") or "\t" not in line:
            continue
        key, values = line.split("\t", 1)
        out[key] = values.split()
    return out


def readings(text):
    """pinyin-data：字 → 首选读音。"""
    out = {}
    for line in text.splitlines():
        if not line.startswith("U+"):
            continue
        code, rest = line.split(":", 1)
        values = rest.split("#", 1)[0].strip()
        if values:
            out[chr(int(code[2:], 16))] = values.split(",")[0].strip()
    return out


def build(lines, ts, st_chars, st_phrases, pinyin):
    """lines：原词库行（含 # 元信息）。返回新行列表与新增条数（纯函数，供自检）。"""
    meta, entries = [], {}
    order = []
    for line in lines:
        if line.startswith("#"):
            meta.append(line)
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            entries[parts[0]] = (parts[1], int(parts[2]))
            order.append(parts[0])
    added = []
    for trad, simps in sorted(ts.items()):
        if len(trad) != 1 or trad in entries:
            continue
        known = [entries[s] for s in simps if s in entries]
        if not known:
            continue
        ann = pinyin.get(trad) or known[0][0]
        added.append((trad, ann, min(r for _a, r in known)))
    # 字表外的冷僻字（叕 龘 沝…）：pinyin-data 有读音的 BMP 汉字一律补上，rank 9000
    seen = set(entries) | {k for k, _a, _r in added}
    for ch, ann in sorted(pinyin.items()):
        if 0x3400 <= ord(ch) <= 0x9FFF and ch not in seen:
            added.append((ch, ann, OUT_OF_TABLE_RANK))
    have = set(entries) | {k for k, _a, _r in added}
    for key in order:
        # 已含繁体字（只在繁→简表里、不是简体字）的词组是上次追加的，跳过，保证重复运行结果不变
        if len(key) < 2 or any(c in ts and c not in st_chars for c in key):
            continue
        trad = st_phrases[key][0] if key in st_phrases else "".join(
            (st_chars.get(c) or [c])[0] for c in key)
        if trad != key and trad not in have:
            have.add(trad)
            ann, rank = entries[key]
            added.append((trad, ann, rank))
    out_meta = []
    for line in meta:
        if line.startswith("#name="):
            line = NAME
        elif line.startswith("#license="):
            line = LICENSE
        elif line.startswith("#version="):
            line = "#version=" + datetime.date.today().strftime("%Y.%m.%d")
        out_meta.append(line)
    body = ["%s\t%s\t%d" % (k, *entries[k]) for k in order] + ["%s\t%s\t%d" % row for row in added]
    return out_meta + body, len(added)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", help="离线数据目录（含 %s）" % ", ".join(FILES))
    args = ap.parse_args()
    path = os.path.join(OUT_DIR, PART)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    ts = pairs(load("TSCharacters.txt", args.data))
    st_chars = pairs(load("STCharacters.txt", args.data))
    st_phrases = pairs(load("STPhrases.txt", args.data))
    pinyin = readings(load("pinyin.txt", args.data))
    out, n = build(lines, ts, st_chars, st_phrases, pinyin)
    raw = ("\n".join(out) + "\n").encode("utf-8")
    with open(path, "wb") as f:
        f.write(raw)
    sha = hashlib.sha256(raw).hexdigest()
    entries = sum(1 for line in out if not line.startswith("#"))
    manifest = {
        "tag": "main",
        "built_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "entries": entries,
        "raw_sha256": sha,
        "raw_size": len(raw),
        "parts": [{"file": PART, "size": len(raw), "sha256": sha}],
    }
    with open(os.path.join(OUT_DIR, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("added %d, entries %d, size %d" % (n, entries, len(raw)))


if __name__ == "__main__":
    main()
