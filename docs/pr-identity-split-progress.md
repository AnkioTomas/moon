# 同一路径两份身份：阅读进度被写进不进书架的那一行

## 现象

图书馆里某本书进度停在 75% 不更新，打开书本确认已读到 100%。进度、阅读统计、笔记全部停在旧值。

## 根因

一个物理文件在 `books` 表里挂了两行，共用同一个 `path`：

| stable_id | deleted | path |
|---|---|---|
| `/mnt/us/documents/books/咸的玩笑 (刘震云).epub` | **1（墓碑）** | 同一路径 |
| `webdav://咸的玩笑 (刘震云).epub` | **0（在架）** | 同一路径 |

`books` 表对 `path` 没有唯一约束，`getByPath` 又没有 `ORDER BY`：

```lua
-- 修复前 book/books_db.lua
function BookDB.getByPath(path)
    return rowToBook(DB.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE path=? LIMIT 1;", path))
end
```

SQLite 按 `idx_books_path` 的顺序返回，稳定命中**先写入的墓碑行**。

`Store.identityFor` 是开书、存进度、记统计的唯一身份入口，它走 `getByPath`。于是：

1. 书架 `Catalog.recentRows` 按 `webdav://` 行显示 → 永远 0.75；
2. 阅读时 `Store.identityFor` 解析到墓碑行 → 进度、`reading_stats`、`notes` 全写到 `deleted=1` 的身份上；
3. 该身份不进书架、也不参与 `webdav://` 的进度/统计同步 → 云端永远拿不到新进度。

墓碑行不进书架，所以真实进度（1.0）在 UI 上完全不可见。

## 触发时序

不是改名、不是多设备、不是手动移动文件。**「先配本地书库目录、后开 WebDAV」的默认路径就会触发**，因为 WebDAV 下载目录默认就是扫描目录。

现场（KindlePaperWhite3，moon 0.4.13 → 0.4.18）的时间线，由 `books.inserted_at` 与 `book.log` 重建：

| 时刻 | 事件 | 库内痕迹 |
|---|---|---|
| 11-03 14:50:46 | 首次扫 `documents/books`，15 本书按**绝对路径**入库 | 15 行 `stable_id=/mnt/...`，`inserted_at` 同为 1793688646 |
| 11-03 17:38–17:48 | 配置 WebDAV，`progress list` / `cover list` 报「路径不存在」 | `book.log:87,88,92,93` |
| 11-03 17:44 / 20:26 | 上传失败 `Request timed out after 300 secs` | `book.log:90,116` |
| **11-03 21:09:56** | WebDAV 书目首次拉通，创建 15 行 `webdav://` | `inserted_at=1793711396` |
| **11-03 21:43:28** | 再次同步，又建 11 行短文件名 `webdav://` | `inserted_at=1793713408` |
| 11-04 09:38:24 | `webdav://` 身份进度停在 0.75 | `pending_progress` |
| **11-05 23:16:04** | 全书读完，进度 1.0 写入**墓碑身份** | `pending_progress` |

### 机制细节

`local.cfg.path = /mnt/us/documents/books`（默认配置），`webdav_path` 为空时 `webdavBookRoot()` 返回同一个目录：

```lua
function Client:webdavBookRoot()
    return localRoot(self) or self:webdavCacheRoot()
end
```

于是 WebDAV 书下载/上传落地后，`Source:openBookAsync` 里：

```lua
local ok, store_err = require("book.store").touch(path, identity)
```

把 `webdav://` 身份的 `path` 写成与绝对路径身份**完全相同**的字符串。

`adoptStableId` 本该在收编时把旧行并掉，但它的第一步是 `DELETE ... AND deleted=1`。若旧行当时是 `deleted=1`（WebDAV 书目 reconcile 已把它下架），这一步删的是**新身份**（不存在），旧墓碑行原样留下 → 两行共享 path。

此后永久自愈失效：`indexLocal` 的收编条件是

```lua
if trusted and (not row or row.path ~= item.path) then adoptLocal(item, ids[i]) end
```

`webdav://` 行的 path 已经正确，条件恒假 → 孤儿墓碑行永远不会被清理。

## 现场数据

设备：KindlePaperWhite3，moon 0.4.18，KOReader v2026.07.1。

### 1. 同一 path 两行

```sql
SELECT stable_id, deleted, sync_status, datetime(inserted_at,'unixepoch','localtime') inserted_at
  FROM books WHERE path='/mnt/us/documents/books/咸的玩笑 (刘震云).epub';
```

```
webdav://咸的玩笑 (刘震云).epub          | 0 | 1 | 2026-11-03 21:09:56
/mnt/us/documents/books/咸的玩笑 (刘震云).epub | 1 | 1 | 2026-11-03 14:50:46
```

### 2. 进度分裂

```sql
SELECT stable_id, fraction, datetime(updated_at,'unixepoch','localtime')
  FROM pending_progress WHERE stable_id LIKE '%咸的玩笑%';
```

```
webdav://咸的玩笑 (刘震云).epub          | 0.75 | 2026-11-04 09:38:24
/mnt/us/documents/books/咸的玩笑 (刘震云).epub | 1.00 | 2026-11-05 23:16:04
```

### 3. 笔记只存在于墓碑身份

```sql
SELECT stable_id, chapter_idx, sync_status FROM notes WHERE stable_id LIKE '%咸的玩笑%';
```

```
/mnt/us/documents/books/咸的玩笑 (刘震云).epub | 0 | 1
```

`webdav://` 身份没有任何笔记行。

### 4. 阅读统计分裂

```sql
SELECT stable_id, count(*), min(datetime(start_time,'unixepoch','localtime')),
       max(datetime(start_time,'unixepoch','localtime'))
  FROM reading_stats WHERE stable_id LIKE '%咸的玩笑%' GROUP BY stable_id;
```

```
webdav://咸的玩笑 (刘震云).epub          | 398 | 2026-10-29 18:49:18 | 2026-11-03 22:47:08
/mnt/us/documents/books/咸的玩笑 (刘震云).epub | 465 | 2026-11-03 18:56:03 | 2026-11-05 23:15:29
```

### 5. `getByPath` 实际命中的是墓碑行

```sql
SELECT stable_id, deleted FROM books
 WHERE path='/mnt/us/documents/books/咸的玩笑 (刘震云).epub' LIMIT 1;
```

```
/mnt/us/documents/books/咸的玩笑 (刘震云).epub | 1
```

### 6. 全库范围

```sql
SELECT count(*) FROM (SELECT path FROM books
  WHERE path IS NOT NULL AND path<>'' GROUP BY path HAVING count(*)>1);
```

```
1
```

全库 15 本本地书，只有这一本已经「激活」成双身份并被读到末尾。另外 3 本（`婚姻中的陌生人`、`时间游戏`、`绿毛水怪 王小波`）的 `webdav://` 行也已登记同一目录下的 path，只是尚未形成墓碑/在架配对，属同类隐患。

## 复现步骤

最小复现（无需真机，纯 DB 层）：

1. 配本地书库目录 `path=/books`，扫盘入库 → 绝对路径身份，`deleted=0`。
2. 配 WebDAV，其中 `webdav_path` 为空（默认），使下载目录 = 扫描目录。
3. 该书在 WebDAV 书目里存在 → 同步时 `reconcile` 把绝对路径身份下架成 `deleted=1`。
4. 同步创建 `webdav://` 身份，用户打开 → `Store.touch` 把 `path` 写成同一字符串。
5. 此时 `getByPath` 返回墓碑行。
6. 读书到 100% → 进度写进墓碑身份 → 书架仍显示 `webdav://` 的旧值。

验证 SQL：步骤 5 的 `SELECT ... LIMIT 1` 返回 `deleted=1` 即为命中。

## 修复

三处，`74b3121f`：

### 1. `getByPath` 在架行优先

```lua
"SELECT " .. COLUMNS .. " FROM books WHERE path=? ORDER BY deleted ASC, inserted_at DESC LIMIT 1;"
```

同一路径有多行时取在架行；都为墓碑时取最近插入的。

### 2. `indexLocal` 认得出孤儿绝对路径身份

```lua
local legacy = local_rows[paths[i]]
if trusted and (not row or row.path ~= item.path or (legacy and legacy.stable_id ~= ids[i])) then
    adoptLocal(item, ids[i])
end
```

原条件只看 `row.path ~= item.path`，path 已正确时永远不收编。现在同路径若还挂着别的身份，也走收编，存量数据一轮同步后自动修复。

### 3. `ProgressDB.moveIdentity` 合并时按时间取新

```lua
-- 修复前：只要旧行不脏就丢弃新身份副本
DELETE ... WHERE ... EXISTS (SELECT 1 ... AND sync_status=0)
-- 修复后：旧行更新更晚（或还没推）才保留旧行
DELETE ... WHERE ... EXISTS (SELECT 1 AS o ...
    AND (o.sync_status=0 OR o.updated_at > pending_progress.updated_at))
```

修复前，旧行是**更新的干净行**时会被 `UPDATE OR IGNORE` 让位后删除，真实进度丢失。这正是 1.0 会被 0.75 覆盖的原因。

## 验证

新增真实 sqlite 回归测试（`tests/book/books_db_downloaded_spec.lua`）：

- 同路径墓碑行遮挡时，`getByPath` 取在架行；
- 两侧都是墓碑时取最近插入的；
- 收编双向取值：旧身份较新 → 保留 1.0；新身份较新 → 保留新值。

| 检查 | 结果 |
|---|---|
| 新增用例在修复前 | FAIL |
| 新增用例在修复后 | PASS（102 assertions） |
| 全量 `./tests/run.sh` | 540 passed, 3 skipped, 0 failed |

在设备库副本上模拟收编，`webdav://咸的玩笑` 合并后拿到 **1.0**，未被 0.75 覆盖。

## 兼容性 / 风险

- `ORDER BY` 是纯查询修正，无 schema 变更。
- `moveIdentity` 的时间戳取舍在两行 `updated_at` 相同时退化为保持现状，仍比原先「必删旧行」安全。
- 存量数据需装包后跑一轮同步才会收编；未收编前 `getByPath` 已能取到在架行，进度不会再写错。

## 相关

独立问题，同一台设备同时确认：`http/turbo/patch.lua` 把 LuaSec 的 `wantwrite` 当错误关流，导致所有 WebDAV 请求硬等到超时（分支 `bugfix/luasocket-wantwrite`）。两者叠加才表现为「同步完全不成功 + 进度不更新」。
