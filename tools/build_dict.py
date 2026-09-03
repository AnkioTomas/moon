#!/usr/bin/env python3
"""下载 StarDict 阅读器常用词典并生成可分发的二进制分片。

用法：python3 tools/build_dict.py [--dict ID ...] [--out-dir assets/dict]

只收录适合阅读期查词的通用词典（按语言分组）；专业/考试/宗教/重复美化版
一律不进默认清单。原始 tar.bz2 不直接提交；每个词典按 15 MiB 切片，
manifest.json 同时记录原始文件和每个分片的 SHA-256。设备端可以按词典
独立下载并拼接，任一词典损坏不会影响其它词典。

只依赖 Python 标准库。数据来源： http://download.huzheng.org/
"""

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import time
import urllib.error
import urllib.request


HOST = "http://download.huzheng.org"
SLICE_MB = 15
RETRIES = 6
USER_AGENT = "moon-dict-builder/1.0"

# lang / lang_name 决定下载页分组；path 是上游子目录；id 是稳定机器标识。
# 挑选原则：阅读期通用查词、体积可控、优先上游标注「推荐」或明确自由许可；
# 跳过专业词典、考试词表、重复美化版、>40MB 的大包（如汉语大词典/康熙图版）。
DICTIONARIES = (
    # —— 简体中文 ——
    {
        "id": "oxford",
        "name": "牛津现代英汉双解词典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-oxford-gb-2.4.2.tar.bz2",
    },
    {
        "id": "langdao-ec",
        "name": "朗道英汉字典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-langdao-ec-gb-2.4.2.tar.bz2",
    },
    {
        "id": "langdao-ce",
        "name": "朗道汉英字典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-langdao-ce-gb-2.4.2.tar.bz2",
    },
    {
        "id": "xhzd",
        "name": "新华字典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-xhzd-2.4.2.tar.bz2",
    },
    {
        "id": "xiandaihanyucidian",
        "name": "现代汉语词典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-xiandaihanyucidian-2.4.2.tar.bz2",
    },
    {
        "id": "ghycyzzd",
        "name": "古汉语常用字字典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-ghycyzzd-2.4.2.tar.bz2",
    },
    {
        "id": "chengyuda",
        "name": "中华成语大词典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-chengyuda-2.4.2.tar.bz2",
    },
    {
        "id": "gaojihanyudacidian",
        "name": "高级汉语大词典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-gaojihanyudacidian_fix-2.4.2.tar.bz2",
    },
    {
        "id": "mdbg-cedict",
        "name": "CC-CEDICT 汉英词典",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-mdbg-cc-cedict-2.4.2.tar.bz2",
    },
    {
        "id": "kangxitext",
        "name": "康熙字典（文字版）",
        "lang": "zh_CN",
        "lang_name": "简体中文",
        "path": "zh_CN",
        "file": "stardict-kangxitext-2.4.2.tar.bz2",
    },
    # —— 英语（单语，读原文时用）——
    {
        "id": "wordnet",
        "name": "WordNet",
        "lang": "en",
        "lang_name": "英语",
        "path": "dict.org",
        "file": "stardict-dictd_www.dict.org_wn-2.4.2.tar.bz2",
    },
    {
        "id": "web1913",
        "name": "Webster's Revised Unabridged Dictionary (1913)",
        "lang": "en",
        "lang_name": "英语",
        "path": "dict.org",
        "file": "stardict-dictd-web1913-2.4.2.tar.bz2",
    },
    # —— 日语 ——
    {
        "id": "jilin-jc",
        "name": "日汉双解词典",
        "lang": "ja",
        "lang_name": "日语",
        "path": "zh_CN",
        "file": "stardict-jilin_jc-2.4.2.tar.bz2",
    },
    {
        "id": "jmdict-ja-en",
        "name": "JMDict 日英词典",
        "lang": "ja",
        "lang_name": "日语",
        "path": "ja",
        "file": "stardict-jmdict-ja-en-2.4.2.tar.bz2",
    },
    # —— 韩语 ——
    {
        "id": "naver-krcn",
        "name": "Naver 韩中词典",
        "lang": "ko",
        "lang_name": "韩语",
        "path": "zh_CN",
        "file": "stardict-naver_krcn-2.4.2.tar.bz2",
    },
    {
        "id": "naver-cnkr",
        "name": "Naver 中韩词典",
        "lang": "ko",
        "lang_name": "韩语",
        "path": "zh_CN",
        "file": "stardict-naver_cnkr-2.4.2.tar.bz2",
    },
    # —— 德语 ——
    {
        "id": "xindehan",
        "name": "新德汉词典",
        "lang": "de",
        "lang_name": "德语",
        "path": "zh_CN",
        "file": "stardict-xindehan-2.4.2.tar.bz2",
    },
    # —— 法语 ——
    {
        "id": "fccf",
        "name": "法汉汉法词典",
        "lang": "fr",
        "lang_name": "法语",
        "path": "zh_CN",
        "file": "stardict-fccf-2.4.2.tar.bz2",
    },
    # —— 俄语 ——
    {
        "id": "yidiantong-ehan",
        "name": "一典通俄汉词典",
        "lang": "ru",
        "lang_name": "俄语",
        "path": "zh_CN",
        "file": "stardict-yidiantong_ehan-2.4.2.tar.bz2",
    },
)

# 下载页语言分组顺序（未列出的语言排在末尾）。
LANG_ORDER = ("zh_CN", "en", "ja", "ko", "de", "fr", "ru")


def fetch(url, dest, retries=RETRIES):
    """下载到临时文件，网络失败时指数退避重试。"""
    last_error = None
    for attempt in range(retries):
        try:
            # 上游老 HTTP/1.0 服务经代理复用连接时偶发 502；明确关闭连接。
            request = urllib.request.Request(
                url, headers={"User-Agent": USER_AGENT, "Connection": "close"}
            )
            with urllib.request.urlopen(request, timeout=180) as response:
                with open(dest, "wb") as output:
                    shutil.copyfileobj(response, output, length=1024 * 1024)
            return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            if attempt + 1 == retries:
                break
            delay = min(2 ** attempt, 30)
            print(f"[warn] 下载失败（{error}），{delay}s 后重试 {attempt + 1}/{retries}")
            time.sleep(delay)
    raise RuntimeError(f"下载失败: {url}") from last_error


def split_file(path, out_dir, dictionary_id, slice_bytes):
    """流式切片，返回原始文件大小、摘要和 manifest 分片列表。"""
    raw_digest = hashlib.sha256()
    raw_size = 0
    parts = []
    with open(path, "rb") as source:
        index = 1
        while True:
            data = source.read(slice_bytes)
            if not data:
                break
            raw_digest.update(data)
            raw_size += len(data)
            filename = f"{dictionary_id}.part.{index:03d}"
            part_path = os.path.join(out_dir, filename)
            with open(part_path, "wb") as part:
                part.write(data)
            parts.append(
                {
                    "file": filename,
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
            index += 1
    return raw_size, raw_digest.hexdigest(), parts


def remove_old_parts(out_dir, dictionary_id):
    prefix = f"{dictionary_id}.part."
    for filename in os.listdir(out_dir):
        if filename.startswith(prefix):
            os.remove(os.path.join(out_dir, filename))


def lang_sort_key(lang):
    try:
        return LANG_ORDER.index(lang)
    except ValueError:
        return len(LANG_ORDER)


def ordered_dictionaries(manifest_entries):
    """按语言分组顺序输出；同语言内保持 DICTIONARIES 声明顺序。"""
    order = {item["id"]: index for index, item in enumerate(DICTIONARIES)}
    selected = [item for item in DICTIONARIES if item["id"] in manifest_entries]
    selected.sort(key=lambda item: (lang_sort_key(item["lang"]), order[item["id"]]))
    return selected

def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dict",
        dest="dictionary_ids",
        action="append",
        choices=[item["id"] for item in DICTIONARIES],
        help="只构建指定词典；可重复传入，缺省构建全部",
    )
    parser.add_argument("--out-dir", default="assets/dict")
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--slice-mb", type=float, default=SLICE_MB)
    args = parser.parse_args(argv)
    if args.slice_mb <= 0:
        parser.error("--slice-mb 必须大于 0")

    selected_ids = args.dictionary_ids or [item["id"] for item in DICTIONARIES]
    selected = [item for item in DICTIONARIES if item["id"] in selected_ids]
    slice_bytes = int(args.slice_mb * 1024 * 1024)
    if slice_bytes < 1:
        parser.error("--slice-mb 太小")
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)
    host = args.host.rstrip("/")
    built_at = time.strftime("%Y-%m-%d %H:%M:%S")
    # 选择性更新时保留其它词典的 manifest 条目；否则更新一个词典会让
    # 设备端误以为其它仍在磁盘上的分片已经不存在。
    old_manifest = os.path.join(out_dir, "manifest.json")
    old_entries = {}
    if os.path.isfile(old_manifest):
        try:
            with open(old_manifest, encoding="utf-8") as source:
                saved = json.load(source)
            old_entries = {
                item["id"]: item
                for item in saved.get("dictionaries", [])
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            }
        except (OSError, ValueError, TypeError, AttributeError):
            old_entries = {}
    manifest_entries = dict(old_entries)

    with tempfile.TemporaryDirectory(prefix="moon-dict-") as temp_dir:
        for dictionary in selected:
            archive = os.path.join(temp_dir, dictionary["file"])
            url = f"{host}/{dictionary['path']}/{dictionary['file']}"
            print(f"fetch [{dictionary['lang']}] {dictionary['name']} ({url}) ...")
            fetch(url, archive)
            remove_old_parts(out_dir, dictionary["id"])
            size, digest, parts = split_file(
                archive, out_dir, dictionary["id"], slice_bytes
            )
            manifest_entries[dictionary["id"]] = {
                "id": dictionary["id"],
                "name": dictionary["name"],
                "lang": dictionary["lang"],
                "lang_name": dictionary["lang_name"],
                "source": url,
                "file": dictionary["file"],
                "size": size,
                "sha256": digest,
                "parts": parts,
            }
            print(f"  {size / 1024 / 1024:.1f} MB, {len(parts)} 片")

    # 旧条目若缺 lang，用当前 DICTIONARIES 声明补齐，避免 UI 分组丢项。
    known = {item["id"]: item for item in DICTIONARIES}
    for item_id, entry in list(manifest_entries.items()):
        meta = known.get(item_id)
        if not meta:
            continue
        entry.setdefault("lang", meta["lang"])
        entry.setdefault("lang_name", meta["lang_name"])

    languages = []
    seen_lang = set()
    for dictionary in ordered_dictionaries(manifest_entries):
        lang = dictionary["lang"]
        if lang in seen_lang:
            continue
        seen_lang.add(lang)
        languages.append({"id": lang, "name": dictionary["lang_name"]})

    manifest = {
        "source": host + "/",
        "built_at": built_at,
        "slice_size": slice_bytes,
        "languages": languages,
        "dictionaries": [
            manifest_entries[dictionary["id"]]
            for dictionary in ordered_dictionaries(manifest_entries)
        ],
    }
    manifest_path = os.path.join(out_dir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(f"manifest: {manifest_path}")
    print(f"languages: {', '.join(item['name'] for item in languages)}")


if __name__ == "__main__":
    main()
