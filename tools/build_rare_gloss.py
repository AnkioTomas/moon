#!/usr/bin/env python3
"""WordWise 短释义词库：assets/rare/en-gloss-zh 与 en-gloss-en。

词表与 rank 对齐现有 assets/rare/en-ipa（同源 ECDICT 词频）；标注来源：

  - en-gloss-zh：ECDICT StarDict（简明英汉）首义中文短译
  - en-gloss-en：Princeton WordNet 首同义词，否则截短定义

只用 Python 标准库。输出覆盖 lexicon.tsv.part.001 并重写 manifest.json。

  python3 tools/build_rare_gloss.py \\
      --ecdict /tmp/ecdict/stardict/stardict-ecdict-2.4.2 \\
      --wordnet /tmp/wordnet/dict

  # 缺目录时按常量 URL 下载到 --cache（默认 /tmp/moon-rare-gloss）
  python3 tools/build_rare_gloss.py
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import struct
import tarfile
import urllib.request
import zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
IPA_PART = os.path.join(ROOT, "assets", "rare", "en-ipa", "lexicon.tsv.part.001")
OUT_ROOT = os.path.join(ROOT, "assets", "rare")

ECDICT_URL = "https://github.com/skywind3000/ECDICT/releases/download/1.0.28/ecdict-stardict-28.zip"
WORDNET_URL = "https://wordnetcode.princeton.edu/wn3.1.dict.tar.gz"

LEVELS = "20000,8000,3000"
ZH_MAX = 10  # 汉字上限（按码点）
EN_MAX_CHARS = 24
EN_MAX_WORDS = 4

POS_LINE = re.compile(r"^[a-z]+\.\s+(.+)$", re.I)
SKIP_LINE = re.compile(r"^(\*|\[|\(|（)")


def fetch(url: str, dest: str) -> None:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        return
    req = urllib.request.Request(url, headers={"User-Agent": "moon-rare-gloss-builder"})
    with urllib.request.urlopen(req, timeout=300) as res, open(dest, "wb") as out:
        while True:
            chunk = res.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def ensure_ecdict(cache: str, path: str | None) -> str:
    if path:
        return path
    zpath = os.path.join(cache, "ecdict-stardict-28.zip")
    dest = os.path.join(cache, "stardict-ecdict-2.4.2")
    if not os.path.isdir(dest):
        fetch(ECDICT_URL, zpath)
        with zipfile.ZipFile(zpath) as zf:
            zf.extractall(cache)
        # zip 顶层目录名 stardict-ecdict-2.4.2/
    if not os.path.isdir(dest):
        raise SystemExit(f"ECDICT not found under {cache}")
    return dest


def ensure_wordnet(cache: str, path: str | None) -> str:
    if path:
        return path
    tpath = os.path.join(cache, "wn3.1.dict.tar.gz")
    dest = os.path.join(cache, "wordnet-dict")
    marker = os.path.join(dest, "data.noun")
    if not os.path.isfile(marker):
        fetch(WORDNET_URL, tpath)
        os.makedirs(dest, exist_ok=True)
        with tarfile.open(tpath, "r:gz") as tar:
            # 归档里是 dict/...
            for member in tar.getmembers():
                name = member.name
                if not name.startswith("dict/") or name.endswith("/"):
                    continue
                member.name = name[len("dict/") :]
                tar.extract(member, dest)
    return dest


def load_ipa_ranks(path: str) -> dict[str, int]:
    ranks: dict[str, int] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or "\t" not in line:
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3 and parts[0]:
                ranks[parts[0]] = int(parts[2])
    return ranks


def load_stardict(dir_path: str) -> dict[str, str]:
    """word → raw definition text（只收纯小写字母词，与 en-ipa 对齐）。"""
    base = None
    for name in os.listdir(dir_path):
        if name.endswith(".ifo"):
            base = os.path.join(dir_path, name[: -len(".ifo")])
            break
    if not base:
        # 目录本身就是含 ifo 的文件夹，或嵌套一层
        for root, _dirs, files in os.walk(dir_path):
            for name in files:
                if name.endswith(".ifo"):
                    base = os.path.join(root, name[: -len(".ifo")])
                    break
            if base:
                break
    if not base:
        raise SystemExit(f"no .ifo under {dir_path}")
    idx = open(base + ".idx", "rb").read()
    data = open(base + ".dict", "rb").read()
    out: dict[str, str] = {}
    i = 0
    n = len(idx)
    while i < n:
        z = idx.find(b"\x00", i)
        if z < 0 or z + 9 > n:
            break
        word_b = idx[i:z]
        offset, size = struct.unpack(">II", idx[z + 1 : z + 9])
        i = z + 9
        try:
            word = word_b.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if not word.isascii() or not word.isalpha() or not word.islower():
            continue
        if offset + size > len(data):
            continue
        try:
            out[word] = data[offset : offset + size].decode("utf-8")
        except UnicodeDecodeError:
            continue
    return out


def zh_gloss(raw: str) -> str | None:
    for line in raw.splitlines():
        line = line.strip()
        if not line or SKIP_LINE.match(line):
            continue
        m = POS_LINE.match(line)
        if not m:
            continue
        body = m.group(1)
        # 去掉尾部网络/地名括注前的主译
        body = re.split(r"[\[【]", body, maxsplit=1)[0]
        first = re.split(r"[,，;；、]", body, maxsplit=1)[0].strip()
        first = first.strip(" 。．.")
        if not first:
            continue
        # 按码点截断
        chars = list(first)
        if len(chars) > ZH_MAX:
            first = "".join(chars[:ZH_MAX])
        if first:
            return first
    return None


def load_wordnet_defs(dict_dir: str) -> dict[str, str]:
    """lemma → 短英文释义（同义词优先，否则定义截断）。"""
    poses = ("noun", "verb", "adj", "adv")
    data_lines: dict[str, dict[str, str]] = {}
    for pos in poses:
        by_off: dict[str, str] = {}
        with open(os.path.join(dict_dir, f"data.{pos}"), encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(" ") or not line.strip():
                    continue
                # offset ... | definition
                if " | " not in line:
                    continue
                head, gloss = line.split(" | ", 1)
                off = head.split()[0]
                # synonyms sit after ss_type / lex_filenum / ss_type fields… take words before pointer count
                # format: off lex_filenum ss_type w_cnt word lex_id ...
                parts = head.split()
                if len(parts) < 5:
                    continue
                try:
                    w_cnt = int(parts[3], 16)
                except ValueError:
                    continue
                syns = []
                j = 4
                for _ in range(w_cnt):
                    if j >= len(parts):
                        break
                    syns.append(parts[j].replace("_", " "))
                    j += 2  # word + lex_id
                gloss = gloss.split(";")[0].strip()
                by_off[off] = json.dumps({"syns": syns, "def": gloss}, ensure_ascii=False)
        data_lines[pos] = by_off

    out: dict[str, str] = {}
    for pos in poses:
        index_path = os.path.join(dict_dir, f"index.{pos}")
        with open(index_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(" ") or not line.strip():
                    continue
                parts = line.split()
                lemma = parts[0].replace("_", " ")
                if " " in lemma or not lemma.isalpha() or not lemma.islower():
                    continue
                if lemma in out:
                    continue
                p_cnt = int(parts[3])
                i = 4 + p_cnt
                sense_cnt = int(parts[i])
                i += 2  # sense_cnt + tagsense_cnt
                for k in range(sense_cnt):
                    off = parts[i + k]
                    payload = data_lines[pos].get(off)
                    if not payload:
                        continue
                    info = json.loads(payload)
                    gloss = shorten_en(lemma, info["syns"], info["def"])
                    if gloss:
                        out[lemma] = gloss
                        break
    return out


def _clean_syn(syn: str) -> str | None:
    s = syn.lower().strip()
    # 不要 all(a)、w.h.o.、带括号的脏同义词
    if not s or re.search(r"[^a-z\s\-]", s):
        return None
    return s


def shorten_en(lemma: str, syns: list[str], definition: str) -> str | None:
    for syn in syns:
        s = _clean_syn(syn)
        if s and s != lemma and " " not in s:
            return s
    for syn in syns:
        s = _clean_syn(syn)
        if not s or s == lemma or len(s) > EN_MAX_CHARS:
            continue
        words = s.split()
        if 0 < len(words) <= EN_MAX_WORDS:
            return s
    text = definition.strip()
    if not text:
        return None
    text = re.sub(r"^(a|an|the|to)\s+", "", text, flags=re.I)
    words = text.split()
    clipped: list[str] = []
    for w in words:
        trial = (" ".join(clipped + [w])).strip(",.;:")
        if len(clipped) >= EN_MAX_WORDS or len(trial) > EN_MAX_CHARS:
            break
        clipped.append(w.strip(",.;:"))
    out = " ".join(clipped).strip(",.;: ")
    return out or None


def write_lexicon(out_dir: str, name: str, license_line: str, entries: list[tuple[str, str, int]]) -> None:
    os.makedirs(out_dir, exist_ok=True)
    entries.sort(key=lambda x: (x[2], x[0]))
    lines = [
        f"#name={name}",
        "#lang=en",
        "#kind=wordwise",
        f"#version={datetime.date.today().isoformat()}",
        license_line,
        f"#levels={LEVELS}",
    ]
    for word, ann, rank in entries:
        # 禁止 tab/换行进标注
        ann = ann.replace("\t", " ").replace("\n", " ").strip()
        if not ann:
            continue
        lines.append(f"{word}\t{ann}\t{rank}")
    text = "\n".join(lines) + "\n"
    part = "lexicon.tsv.part.001"
    part_path = os.path.join(out_dir, part)
    with open(part_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    raw = text.encode("utf-8")
    digest = hashlib.sha256(raw).hexdigest()
    manifest = {
        "tag": "main",
        "built_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "entries": len(entries),
        "raw_sha256": digest,
        "raw_size": len(raw),
        "parts": [{"file": part, "size": len(raw), "sha256": digest}],
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{out_dir}: {len(entries)} entries, {len(raw)} bytes")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ecdict", help="ECDICT StarDict 目录（含 .ifo/.idx/.dict）")
    ap.add_argument("--wordnet", help="WordNet dict 目录（含 data.noun 等）")
    ap.add_argument("--cache", default="/tmp/moon-rare-gloss", help="下载缓存目录")
    ap.add_argument("--ipa", default=IPA_PART, help="en-ipa 词库（取词与 rank）")
    args = ap.parse_args()

    ranks = load_ipa_ranks(args.ipa)
    print(f"ipa words: {len(ranks)}")

    ecdict_dir = ensure_ecdict(args.cache, args.ecdict)
    stardict = load_stardict(ecdict_dir)
    print(f"ecdict words: {len(stardict)}")

    zh_entries: list[tuple[str, str, int]] = []
    for word, rank in ranks.items():
        raw = stardict.get(word)
        if not raw:
            continue
        gloss = zh_gloss(raw)
        if gloss:
            zh_entries.append((word, gloss, rank))

    write_lexicon(
        os.path.join(OUT_ROOT, "en-gloss-zh"),
        "English gloss (zh, ECDICT)",
        "#license=MIT (skywind3000/ECDICT); ranks from en-ipa / ECDICT frequency",
        zh_entries,
    )

    wn_dir = ensure_wordnet(args.cache, args.wordnet)
    en_defs = load_wordnet_defs(wn_dir)
    print(f"wordnet lemmas: {len(en_defs)}")
    en_entries: list[tuple[str, str, int]] = []
    for word, rank in ranks.items():
        gloss = en_defs.get(word)
        if gloss:
            en_entries.append((word, gloss, rank))

    write_lexicon(
        os.path.join(OUT_ROOT, "en-gloss-en"),
        "English gloss (en, WordNet)",
        "#license=WordNet 3.1 (Princeton); ranks from en-ipa / ECDICT frequency",
        en_entries,
    )


if __name__ == "__main__":
    main()
