#!/usr/bin/env python3
"""下载 StarDict 中文词典并生成可分发的二进制分片。

用法：python3 tools/build_dict.py [--dict ID ...] [--out-dir assets/dict]

默认下载四个词典：牛津现代英汉双解词典、新华字典、现代汉语词典、
古汉语常用字字典。原始 tar.bz2 不直接提交；每个词典按 15 MiB 切片，
manifest.json 同时记录原始文件和每个分片的 SHA-256。设备端可以按词典
独立下载并拼接，任一词典损坏不会影响其它词典。

只依赖 Python 标准库。数据来源： http://download.huzheng.org/zh_CN/
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


BASE_URL = "http://download.huzheng.org/zh_CN/"
SLICE_MB = 15
RETRIES = 6
USER_AGENT = "moon-dict-builder/1.0"

# 文件名来自上游目录；id 是 manifest 和分片文件名中稳定的机器标识。
DICTIONARIES = (
    {
        "id": "oxford",
        "name": "牛津现代英汉双解词典",
        "file": "stardict-oxford-gb-2.4.2.tar.bz2",
    },
    {
        "id": "xhzd",
        "name": "新华字典",
        "file": "stardict-xhzd-2.4.2.tar.bz2",
    },
    {
        "id": "xiandaihanyucidian",
        "name": "现代汉语词典",
        "file": "stardict-xiandaihanyucidian-2.4.2.tar.bz2",
    },
    {
        "id": "ghycyzzd",
        "name": "古汉语常用字字典",
        "file": "stardict-ghycyzzd-2.4.2.tar.bz2",
    },
)


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


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dict",
        dest="dictionary_ids",
        action="append",
        choices=[item["id"] for item in DICTIONARIES],
        help="只构建指定词典；可重复传入，缺省构建全部四个",
    )
    parser.add_argument("--out-dir", default="assets/dict")
    parser.add_argument("--base-url", default=BASE_URL)
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
    base_url = args.base_url.rstrip("/") + "/"
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
            url = base_url + dictionary["file"]
            print(f"fetch {dictionary['name']} ({url}) ...")
            fetch(url, archive)
            remove_old_parts(out_dir, dictionary["id"])
            size, digest, parts = split_file(
                archive, out_dir, dictionary["id"], slice_bytes
            )
            manifest_entries[dictionary["id"]] = {
                "id": dictionary["id"],
                "name": dictionary["name"],
                "source": url,
                "file": dictionary["file"],
                "size": size,
                "sha256": digest,
                "parts": parts,
            }
            print(f"  {size / 1024 / 1024:.1f} MB, {len(parts)} 片")

    manifest = {
        "source": base_url,
        "built_at": built_at,
        "slice_size": slice_bytes,
        "dictionaries": [
            manifest_entries[dictionary["id"]]
            for dictionary in DICTIONARIES
            if dictionary["id"] in manifest_entries
        ],
    }
    manifest_path = os.path.join(out_dir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(f"manifest: {manifest_path}")


if __name__ == "__main__":
    main()
