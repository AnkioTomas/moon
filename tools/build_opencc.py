#!/usr/bin/env python3
"""OpenCC 简繁转换表 → 输入法用的只读 SQLite（book.koplugin/features/ime/opencc.sqlite3）。

仅依赖 Python 标准库。数据来源 OpenCC（Apache-2.0），版本固定在 REF。

schema：
  meta(k PRIMARY KEY, v)                     -- source / s2t_max / t2s_max（最长源词字数）
  s2t(k PRIMARY KEY, v) WITHOUT ROWID        -- 简 → 繁
  t2s(k PRIMARY KEY, v) WITHOUT ROWID        -- 繁 → 简

一对多的单字取 OpenCC 的首选。词组只保留「逐字转换结果 ≠ 词组结果」的条目（如 头发 → 頭髮），
其余由单字就能转对。运行时不把表读进内存：每次查词把候选词的全部子串一次 IN 查询取回，再做最长匹配。

  python3 tools/build_opencc.py
"""

import os
import sqlite3
import urllib.request

REF = "ver.1.1.9"
BASE = "https://raw.githubusercontent.com/BYVoid/OpenCC/%s/data/dictionary/" % REF
OUT = os.path.join(os.path.dirname(__file__), "..", "book.koplugin", "features", "ime", "opencc.sqlite3")
UA = {"User-Agent": "moon-opencc-builder"}

TABLES = {
    "s2t": ("STCharacters.txt", "STPhrases.txt"),
    "t2s": ("TSCharacters.txt", "TSPhrases.txt"),
}


def fetch(name):
    with urllib.request.urlopen(urllib.request.Request(BASE + name, headers=UA), timeout=60) as res:
        text = res.read().decode("utf-8")
    pairs = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        key, values = line.split("\t", 1)
        pairs[key] = values.split(" ")[0]
    return pairs


def build(chars_file, phrases_file):
    chars = fetch(chars_file)
    phrases = fetch(phrases_file)
    rows = {k: v for k, v in chars.items() if k != v}
    for key, value in phrases.items():
        if "".join(chars.get(c, c) for c in key) != value:
            rows[key] = value
    return rows


def main():
    if os.path.exists(OUT):
        os.remove(OUT)
    conn = sqlite3.connect(OUT)
    conn.execute("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL)")
    conn.execute("INSERT INTO meta VALUES('source', ?)", ("OpenCC %s (Apache-2.0) https://github.com/BYVoid/OpenCC" % REF,))
    for name, (chars_file, phrases_file) in TABLES.items():
        rows = build(chars_file, phrases_file)
        conn.execute("CREATE TABLE %s(k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID" % name)
        conn.executemany("INSERT INTO %s VALUES(?, ?)" % name, sorted(rows.items()))
        conn.execute("INSERT INTO meta VALUES(?, ?)", (name + "_max", str(max(len(k) for k in rows))))
        print("%s: %d entries" % (name, len(rows)))
    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    print("%s: %d bytes" % (OUT, os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
