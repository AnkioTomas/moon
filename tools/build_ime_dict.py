#!/usr/bin/env python3
"""五笔、仓颉、注音词库 → 月读 IME SQLite 分片。

仅依赖 Python 标准库。词库来源与许可证见 book.koplugin/ime/THIRD_PARTY.md。
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
import urllib.request

SLICE_SIZE = 15 * 1024 * 1024
SCHEMA_VERSION = "1"
UA = {"User-Agent": "moon-ime-dict-builder"}

SOURCES = {
    "wubi": {
        "repo": "KyleBing/rime-wubi86-jidian",
        "ref": "master",
        "files": [
            "wubi86_jidian.dict.yaml",
            "wubi86_jidian_extra.dict.yaml",
        ],
    },
    "cangjie": {
        "repo": "Jackchows/Cangjie5",
        "ref": "master",
        "files": ["Cangjie5_TC.txt"],
    },
    "zhuyin": {
        "repo": "openvanilla/McBopomofo",
        "ref": "master",
        "files": [
            "Source/Data/BPMFBase.txt",
            "Source/Data/BPMFMappings.txt",
            "Source/Data/phrase.occ",
        ],
    },
}


def fetch(url, path):
    error = None
    for attempt in range(6):
        try:
            request = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(request, timeout=180) as response:
                data = response.read()
            with open(path, "wb") as output:
                output.write(data)
            return
        except Exception as caught:  # 网络失败只能有限重试，最终仍然报错
            error = caught
            delay = min(2 ** attempt, 30)
            print(f"[warn] fetch failed ({caught}), retry in {delay}s", file=sys.stderr)
            time.sleep(delay)
    raise error


def source_url(source, name, ref):
    return f"https://raw.githubusercontent.com/{source['repo']}/{ref}/{name}"


def yaml_entries(path):
    header = False
    started = False
    with open(path, encoding="utf-8") as source:
        for line in source:
            line = line.strip()
            if not started:
                if line == "---":
                    header = True
                    continue
                if header and line == "...":
                    started = True
                    continue
                if header or not line or line.startswith("#"):
                    continue
                started = True
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) < 2 or not re.fullmatch(r"[a-z]+", fields[1]):
                continue
            weight = int(fields[2]) if len(fields) > 2 and fields[2].isdigit() else 0
            yield fields[0], fields[1], weight


def cangjie_entries(path):
    with open(path, encoding="utf-8") as source:
        for line in source:
            fields = line.split()
            if len(fields) >= 2 and re.fullmatch(r"[a-z]+", fields[1]):
                yield fields[0], fields[1], 0


def occurrence_weights(path):
    weights = {}
    with open(path, encoding="utf-8") as source:
        for line in source:
            word, separator, count = line.rstrip().rpartition(" ")
            if separator and count.isdigit():
                weights[word] = int(count)
    return weights


def valid_zhuyin(code):
    return code and all(
        "\u3105" <= char <= "\u312f" or char in "ˉˊˇˋ˙"
        for char in code
    )


def zhuyin_entries(base_path, mapping_path, occurrence_path):
    weights = occurrence_weights(occurrence_path)
    with open(base_path, encoding="utf-8") as source:
        for line in source:
            fields = line.split()
            if len(fields) >= 2 and valid_zhuyin(fields[1]):
                yield fields[0], fields[1], weights.get(fields[0], 0)
    with open(mapping_path, encoding="utf-8") as source:
        for line in source:
            fields = line.split()
            if len(fields) < 2:
                continue
            word = fields[0]
            code = "".join(fields[1:])
            if valid_zhuyin(code):
                yield word, code, weights.get(word, 0)


def read_entries(method, paths):
    if method == "wubi":
        for path in paths:
            yield from yaml_entries(path)
    elif method == "cangjie":
        yield from cangjie_entries(paths[0])
    else:
        yield from zhuyin_entries(paths[0], paths[1], paths[2])


def assemble(out_dir):
    manifest_path = os.path.join(out_dir, "manifest.json")
    with open(manifest_path, encoding="utf-8") as source:
        manifest = json.load(source)
    output_path = os.path.join(out_dir, "dictionary.sqlite3")
    digest = hashlib.sha256()
    size = 0
    with open(output_path, "wb") as output:
        for part in manifest["parts"]:
            path = os.path.join(out_dir, part["file"])
            with open(path, "rb") as source:
                data = source.read()
            if len(data) != part["size"] or hashlib.sha256(data).hexdigest() != part["sha256"]:
                raise ValueError(f"bad part: {part['file']}")
            output.write(data)
            digest.update(data)
            size += len(data)
    if size != manifest["raw_size"] or digest.hexdigest() != manifest["raw_sha256"]:
        os.remove(output_path)
        raise ValueError("assembled dictionary checksum mismatch")
    print(output_path)


def write_parts(raw_path, out_dir):
    parts = []
    digest = hashlib.sha256()
    with open(raw_path, "rb") as source:
        while True:
            data = source.read(SLICE_SIZE)
            if not data:
                break
            digest.update(data)
            name = f"dictionary.sqlite3.part.{len(parts) + 1:03d}"
            with open(os.path.join(out_dir, name), "wb") as output:
                output.write(data)
            parts.append({
                "file": name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            })
    return parts, digest.hexdigest()


def build(args):
    source = SOURCES[args.method]
    ref = args.ref or source["ref"]
    out_dir = args.out_dir or os.path.join("assets", "ime", args.method)
    os.makedirs(out_dir, exist_ok=True)
    for name in os.listdir(out_dir):
        if name.startswith("dictionary.sqlite3.part."):
            os.remove(os.path.join(out_dir, name))

    with tempfile.TemporaryDirectory(prefix=f"moon-{args.method}-") as temp:
        paths = []
        for index, name in enumerate(source["files"]):
            path = os.path.join(temp, str(index))
            print(f"fetch {name}")
            fetch(source_url(source, name, ref), path)
            paths.append(path)

        rows = {}
        order = 0
        for text, code, weight in read_entries(args.method, paths):
            order += 1
            key = (code, text)
            previous = rows.get(key)
            if previous is None or weight > previous[0]:
                rows[key] = (weight, order)

        raw_path = os.path.join(out_dir, "dictionary.sqlite3")
        if os.path.exists(raw_path):
            os.remove(raw_path)
        connection = sqlite3.connect(raw_path)
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("PRAGMA synchronous=OFF")
        connection.execute("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)")
        connection.execute(
            "CREATE TABLE entries("
            "code TEXT NOT NULL, text TEXT NOT NULL, weight INTEGER NOT NULL,"
            "source_order INTEGER NOT NULL, PRIMARY KEY(code, text)) WITHOUT ROWID"
        )
        connection.executemany(
            "INSERT INTO entries(code, text, weight, source_order) VALUES (?, ?, ?, ?)",
            ((code, text, weight, order) for (code, text), (weight, order) in rows.items()),
        )
        connection.execute(
            "CREATE INDEX idx_entries_code ON entries(code, weight DESC, source_order)"
        )
        built_at = time.strftime("%Y-%m-%d %H:%M:%S")
        connection.executemany(
            "INSERT INTO meta(k, v) VALUES (?, ?)",
            [
                ("schema_version", SCHEMA_VERSION),
                ("source_tag", ref),
                ("source_repo", source["repo"]),
                ("built_at", built_at),
                ("entries", str(len(rows))),
            ],
        )
        connection.commit()
        connection.execute("VACUUM")
        connection.close()

    parts, raw_sha = write_parts(raw_path, out_dir)
    manifest = {
        "tag": f"{source['repo']}@{ref}",
        "built_at": built_at,
        "entries": len(rows),
        "raw_sha256": raw_sha,
        "raw_size": os.path.getsize(raw_path),
        "parts": parts,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
    if not args.keep_raw:
        os.remove(raw_path)
    print(f"{args.method}: {len(rows)} entries, {len(parts)} parts")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("method", choices=sorted(SOURCES))
    parser.add_argument("--ref")
    parser.add_argument("--out-dir")
    parser.add_argument("--keep-raw", action="store_true")
    parser.add_argument("--assemble-only", action="store_true")
    args = parser.parse_args()
    out_dir = args.out_dir or os.path.join("assets", "ime", args.method)
    if args.assemble_only:
        assemble(out_dir)
    else:
        build(args)


if __name__ == "__main__":
    main()
