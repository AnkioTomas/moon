#!/usr/bin/env python3
"""rime-ice 词库 → 拼音候选 sqlite（book.koplugin 拼音增强用词库）。

数据来源：https://github.com/iDvel/rime-ice （cn_dicts/ 下 5 个启用文件）
用法：python3 tools/build_pinyin_dict.py [--tag <release-tag>] [--out-dir assets/pinyin]

  --tag     缺省取 rime-ice 最新 release tag，失败回落 main
  --out-dir 缺省 assets/pinyin

产物（--out-dir 下）：

  dictionary.sqlite3.gz.001 / .002 / ...   每片独立 gzip（各自可解压），按序拼出原始 sqlite
  manifest.json                            { tag, built_at, entries, raw_sha256, raw_size,
                                             parts: [{file, size}] }

设备端（pinyin/download.lua）按 manifest 逐片下载，逐片 inflate 解压拼出原始库、
校验 raw_sha256 后落盘成 $DATA/.moon/dictionary.sqlite3。
每片独立 gzip 是为了设备端可以流式解压（libz 无 gzopen，inflate 按片做），
避免整库 gzip 解压时 143MB 的内存峰值；切片是因为整库 gzip 后 ~55MB，
超过 jsdelivr ~20MB 单文件上限。

解压后的 sqlite schema：

  meta(k TEXT PRIMARY KEY, v TEXT)            -- source_tag / built_at / entries
  words(word TEXT, pinyin TEXT, weight INT)   -- pinyin 无声调、空格分隔音节、ü=v
  INDEX idx_pinyin ON words(pinyin, weight DESC)

tencent.dict.yaml 无拼音列，按 8105 字表逐字注音（笛卡尔积）；
读音组合 >=16 的词跳过（组合爆炸截断，统计里可见）。

只依赖标准库。定期更新 = 手动重跑本脚本并提交产物。
"""

import argparse
import gzip
import hashlib
import itertools
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.request

REPO = "iDvel/rime-ice"
CDN = "https://cdn.jsdelivr.net/gh/{repo}@{tag}/cn_dicts/{name}.dict.yaml"
# tencent 必须最后处理（依赖 8105 字表）
DICT_FILES = ["8105", "base", "ext", "others", "tencent"]
MAX_COMBOS = 16         # tencent 单词读音组合上限（达到即弃）
SLICE_MB = 15           # 切片大小（jsdelivr 单文件上限 ~20MB，留余量）

UA = {"User-Agent": "moon-pinyin-dict-builder"}


def fetch(url, dest=None, retries=6):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=180) as r:
                data = r.read()
            if dest:
                with open(dest, "wb") as f:
                    f.write(data)
                return dest
            return data
        except Exception as e:  # noqa: BLE001 — 网络抖动重试，最后一次再抛
            last = e
            wait = min(2 ** attempt, 30)
            print(f"[warn] fetch 失败（{e}），{wait}s 后重试 {attempt + 1}/{retries}", file=sys.stderr)
            time.sleep(wait)
    raise last


def latest_tag():
    try:
        data = fetch(f"https://api.github.com/repos/{REPO}/releases/latest")
        return json.loads(data)["tag_name"]
    except Exception as e:  # noqa: BLE001 — 任何失败都回落 main
        print(f"[warn] 取最新 release 失败（{e}），回落 main", file=sys.stderr)
        return "main"


def iter_entries(path):
    """逐行产出 (word, pinyin|None, weight)。跳过 YAML 头与注释。"""
    in_header = False
    header_done = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not header_done:
                s = line.strip()
                if s == "---":
                    in_header = True
                    continue
                if in_header and (s == "..." or s == "---"):
                    in_header = False
                    header_done = True
                    continue
                if in_header:
                    continue
                # 无 YAML 头的容错：第一行数据即开始
                if s.startswith("#") or s == "":
                    continue
                header_done = True
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 3:
                word, pinyin, weight = parts[0], parts[1], parts[2]
            elif len(parts) == 2:
                # 两列：可能是「词 TAB 拼音」或「词 TAB 权重」，按第二列是否纯字母区分
                word = parts[0]
                if parts[1].replace(" ", "").isalpha():
                    word, pinyin, weight = parts[0], parts[1], "0"
                else:
                    word, pinyin, weight = parts[0], None, parts[1]
            else:
                continue
            try:
                weight = int(weight)
            except ValueError:
                weight = 0
            yield word, pinyin, weight


def valid_word(word):
    """词只留纯非 ASCII（中文等），含字母/数字/空白/标点的跳过。"""
    if not word:
        return False
    for ch in word:
        if ord(ch) < 0x2E80:  # CJK 部首起点以下的全跳（含 ASCII、标点、空白）
            return False
    return True


def valid_pinyin(pinyin):
    if not pinyin:
        return False
    return all(s.isalpha() and s.islower() for s in pinyin.split(" "))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default=None)
    ap.add_argument("--out-dir", default="assets/pinyin")
    args = ap.parse_args()

    tag = args.tag or latest_tag()
    print(f"source: {REPO}@{tag}")

    stats = {}
    char_readings = {}  # 字 → set(读音)
    rows = {}           # (word, pinyin) → weight

    with tempfile.TemporaryDirectory() as tmp:
        for name in DICT_FILES:
            path = os.path.join(tmp, f"{name}.dict.yaml")
            url = CDN.format(repo=REPO, tag=tag, name=name)
            print(f"fetch {name} ...")
            t0 = time.time()
            fetch(url, path)
            size = os.path.getsize(path)
            print(f"  {size / 1024 / 1024:.1f} MB in {time.time() - t0:.0f}s")

            count = skipped = 0
            for word, pinyin, weight in iter_entries(path):
                if name == "8105":
                    # 字表既给 tencent 注音，也作为单字候选直接入库
                    if pinyin and len(word) == 1:
                        char_readings.setdefault(word, set()).add(pinyin)
                        key = (word, pinyin)
                        if key not in rows or rows[key] < weight:
                            rows[key] = weight
                        count += 1
                    continue
                if name == "tencent":
                    if pinyin is not None or not valid_word(word):
                        skipped += 1
                        continue
                    reading_sets = [char_readings.get(ch) for ch in word]
                    if any(rs is None for rs in reading_sets):
                        skipped += 1
                        continue
                    combos = list(itertools.product(*[sorted(r) for r in reading_sets]))
                    if len(combos) >= MAX_COMBOS:
                        skipped += 1
                        continue
                    for combo in combos:
                        py = " ".join(combo)
                        key = (word, py)
                        if key not in rows or rows[key] < weight:
                            rows[key] = weight
                        count += 1
                    continue
                # 自带拼音列的词库
                if not valid_word(word) or not valid_pinyin(pinyin):
                    skipped += 1
                    continue
                key = (word, pinyin)
                if key not in rows or rows[key] < weight:
                    rows[key] = weight
                count += 1
            stats[name] = (count, skipped)
            print(f"  entries={count} skipped={skipped}")

    out_dir = args.out_dir
    os.makedirs(out_dir, exist_ok=True)
    raw_path = os.path.join(out_dir, "dictionary.sqlite3")
    if os.path.exists(raw_path):
        os.remove(raw_path)
    conn = sqlite3.connect(raw_path)
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)")
    conn.execute(
        "CREATE TABLE words(word TEXT NOT NULL, pinyin TEXT NOT NULL,"
        " weight INTEGER NOT NULL DEFAULT 0)"
    )
    conn.executemany(
        "INSERT INTO words(word, pinyin, weight) VALUES (?, ?, ?)",
        ((w, p, wt) for (w, p), wt in rows.items()),
    )
    print("create index ...")
    # 前缀索引：连写输入码（如 "nihao"）经 Lua 侧分隔猜测转成 "ni hao" 后做
    # LIKE 'prefix%' 前缀匹配；(pinyin, weight DESC) 让前缀扫描按权重有序早停
    conn.execute("CREATE INDEX idx_pinyin ON words(pinyin, weight DESC)")
    built_at = time.strftime("%Y-%m-%d %H:%M:%S")
    conn.executemany(
        "INSERT INTO meta(k, v) VALUES (?, ?)",
        [
            ("source_tag", tag),
            ("built_at", built_at),
            ("entries", str(len(rows))),
        ],
    )
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    raw_size = os.path.getsize(raw_path)
    raw_sha = hashlib.sha256()
    slice_raw = SLICE_MB * 1024 * 1024
    parts = []
    buf = b""
    with open(raw_path, "rb") as f:
        while True:
            chunk = f.read(slice_raw - len(buf))
            if not chunk and not buf:
                break
            buf += chunk
            raw_sha.update(chunk)
            if len(buf) < slice_raw:
                if not chunk:
                    break
                continue
            name = f"dictionary.sqlite3.gz.{len(parts) + 1:03d}"
            data = gzip.compress(buf, compresslevel=9)
            with open(os.path.join(out_dir, name), "wb") as fo:
                fo.write(data)
            parts.append({"file": name, "size": len(data)})
            buf = b""
        if buf:
            name = f"dictionary.sqlite3.gz.{len(parts) + 1:03d}"
            data = gzip.compress(buf, compresslevel=9)
            with open(os.path.join(out_dir, name), "wb") as fo:
                fo.write(data)
            parts.append({"file": name, "size": len(data)})
    os.remove(raw_path)

    manifest = {
        "tag": tag,
        "built_at": built_at,
        "entries": len(rows),
        "raw_sha256": raw_sha.hexdigest(),
        "raw_size": raw_size,
        "parts": parts,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    gz_size = sum(p["size"] for p in parts)
    print(f"\ntotal entries: {len(rows)}")
    for name, (count, skipped) in stats.items():
        print(f"  {name}: {count} 条（跳过 {skipped}）")
    print(f"gzip: {gz_size / 1024 / 1024:.1f} MB (解压后 {raw_size / 1024 / 1024:.1f} MB)")
    print(f"parts: {len(parts)} 片 → {out_dir}/dictionary.sqlite3.gz.NNN")
    print(f"manifest: {out_dir}/manifest.json  raw_sha256={raw_sha.hexdigest()[:16]}…")


if __name__ == "__main__":
    main()
