#!/usr/bin/env python3
"""给模拟器的本地源灌假数据：造一批 txt 书、书库行、阅读进度和近 14 个月的逐页阅读记录。

用法：
  tools/seed_local_demo.py          灌入（可重复执行，先清掉上一次灌的）
  tools/seed_local_demo.py --clean  只清理

做的事：
  1. 书放在 <模拟器数据目录>/demo-books/<题材>/<作者> - <书名>.txt
  2. 把 settings/local.lua 的 path 指向这个目录（模拟器已开着就要重进设置或重启才生效）
  3. 往 books / pending_progress / reading_stats 写行，stable_id = 文件绝对路径（local 源约定）
本地源的其它旧行不动；灌入的行都以 demo-books 目录为前缀，清理按前缀删。
"""
import hashlib
import os
import random
import re
import sqlite3
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = "local"
BOOKS = {
    "文学": [("余华", "兄弟"), ("余华", "许三观卖血记"), ("路遥", "平凡的世界"), ("陈忠实", "白鹿原"),
             ("莫言", "蛙"), ("钱钟书", "围城"), ("老舍", "骆驼祥子"), ("沈从文", "边城")],
    "科幻": [("刘慈欣", "三体"), ("刘慈欣", "流浪地球"), ("王晋康", "蚁生"), ("韩松", "地铁"),
             ("郝景芳", "北京折叠"), ("阿西莫夫", "基地"), ("克拉克", "童年的终结")],
    "历史": [("黄仁宇", "万历十五年"), ("吴晗", "朱元璋传"), ("钱穆", "国史大纲"), ("岳南", "南渡北归"),
             ("易中天", "品三国"), ("李开元", "秦崩")],
    "科技": [("吴军", "浪潮之巅"), ("吴军", "数学之美"), ("李笑来", "把时间当作朋友"),
             ("Kernighan", "C程序设计语言"), ("Knuth", "计算机程序设计艺术"), ("周志华", "机器学习")],
    "悬疑": [("东野圭吾", "白夜行"), ("东野圭吾", "嫌疑人X的献身"), ("紫金陈", "无证之罪"),
             ("阿加莎", "东方快车谋杀案"), ("雷米", "心理罪"), ("蔡骏", "镜子的背面")],
}
DAYS = 420
SECTION = "今天的月亮很圆，故事从一个平常的傍晚讲起。\n" * 60


def data_dir():
    cand = sorted((ROOT / "koreader").glob("koreader-emulator-*/koreader"), key=lambda p: p.stat().st_mtime)
    if not cand:
        sys.exit("找不到模拟器数据目录（koreader/koreader-emulator-*/koreader）")
    return cand[-1]


def clean(db, prefix):
    like = prefix + "/%"
    for table in ("reading_stats", "pending_progress", "books"):
        db.execute(f"DELETE FROM {table} WHERE source_id=? AND stable_id LIKE ?", (SOURCE, like))


def set_path(data, books_dir):
    f = data / ".moon" / "settings" / "local.lua"
    text = f.read_text()
    line = f'    ["path"] = "{books_dir}",'
    text = re.sub(r'^\s*\["path"\] = ".*",$', line, text, flags=re.M) if '["path"]' in text \
        else text.replace("return {\n", "return {\n" + line + "\n", 1)
    f.write_text(text)


def make_books(books_dir):
    out = []
    for cat, items in BOOKS.items():
        folder = books_dir / cat
        folder.mkdir(parents=True, exist_ok=True)
        for author, title in items:
            path = folder / f"{author} - {title}.txt"
            path.write_text(f"{title}\n{author}\n\n{SECTION}", encoding="utf-8")
            out.append({"path": str(path), "cat": cat, "author": author, "title": title,
                        "md5": hashlib.md5(path.read_bytes()).hexdigest()})
    return out


def simulate(books, now, rng):
    """从 DAYS 天前按书顺序往后读：返回逐页记录、各书进度（finished 已读完、reading 在读）。"""
    order = books[:]
    rng.shuffle(order)
    for b in order:
        b["total"] = rng.randint(450, 1100)
        b["read"] = 0
        b["last"] = 0
    rows, cur = [], 0
    midnight = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    for ago in range(DAYS, 0, -1):
        day = midnight - ago * 86400
        weekend = time.localtime(day).tm_wday >= 5
        if rng.random() > (0.78 if weekend else 0.62) or cur >= len(order):
            continue
        for _n in range(rng.choice((1, 1, 2, 3))):
            hour = rng.choices((7, 12, 13, 20, 21, 22, 23), (2, 3, 1, 5, 6, 5, 2))[0]
            t = day + hour * 3600 + rng.randint(0, 1800)
            book = order[cur]
            for _p in range(rng.randint(8, 45)):
                dur = rng.randint(35, 130)
                book["read"] += 1
                book["last"] = int(t)
                rows.append((book["path"], book["read"], int(t), dur, book["total"]))
                t += dur
                if book["read"] >= book["total"]:
                    cur += 1
                    if cur >= len(order):
                        break
                    book = order[cur]
            if cur >= len(order):
                break
    return rows


def main():
    data = data_dir()
    books_dir = data / "demo-books"
    prefix = str(books_dir)
    db = sqlite3.connect(data / ".moon" / "book.sqlite3", timeout=30)
    with db:
        clean(db, prefix)
    if "--clean" in sys.argv:
        for p in sorted(books_dir.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
        print("已清理", prefix)
        return

    rng = random.Random(7)
    now = int(time.time())
    books = make_books(books_dir)
    rows = simulate(books, now, rng)
    with db:
        for b in books:
            finished = b["read"] >= b["total"]
            db.execute(
                """INSERT OR REPLACE INTO books (source_id, stable_id, md5, title, authors, category, inserted_at,
                   path, deleted, sync_status, read_state) VALUES (?,?,?,?,?,?,?,?,0,1,0)""",
                (SOURCE, b["path"], b["md5"], b["title"], b["author"], b["cat"], now - DAYS * 86400, b["path"]))
            if b["read"] > 0:
                frac = min(1.0, b["read"] / b["total"])
                db.execute(
                    """INSERT OR REPLACE INTO pending_progress (source_id, stable_id, fraction, page, total_pages,
                       updated_at, sync_status) VALUES (?,?,?,?,?,?,1)""",
                    (SOURCE, b["path"], frac, b["read"], b["total"], b["last"]))
        # sync_status=2：按「从 KOReader 统计导入」处理，不会被当脏行上传
        db.executemany(
            """INSERT INTO reading_stats (source_id, stable_id, record_type, page, start_time, duration, total_pages,
               sync_status, last_time) VALUES (?,?, 'page', ?,?,?,?, 2, ?)""",
            [(SOURCE, p, pg, t, d, tot, t + d) for p, pg, t, d, tot in rows])
    set_path(data, books_dir)
    done = sum(1 for b in books if b["read"] >= b["total"])
    reading = sum(1 for b in books if 0 < b["read"] < b["total"])
    print(f"书 {len(books)} 本（读完 {done}、在读 {reading}），阅读记录 {len(rows)} 条，目录 {prefix}")
    print("local.lua 的 path 已改；模拟器开着的话请重启或重进设置页让它重读。")


main()
