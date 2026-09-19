# book.sync — 四域同步编排

代码：[`book/sync.lua`](../../book.koplugin/book/sync.lua)。

## 设计

只负责**顺序、取消、汇总**，不碰源协议。固定顺序：

```text
books → progress → notes → stats
```

| 域 | 编排层行为 | Pull 时机 |
|---|---|---|
| books | 全量可 pull；`dirty_only` 只推删/加 | 全量同步 |
| progress | **永远强制 `dirty_only`** | 仅开书 `Progress.pull` |
| notes | **永远强制 `dirty_only`** | 仅开书 `Note.pull` |
| stats | 跟随 opts；脏重试通常只推 | 全量 / 源 `stats_pull` |

任一域失败 → 中断后续域（已成功域的计数仍在 summary，但不回调成功）。源未实现对应方法 → 记 `skipped`，不算失败。

`retryDirtyAsync`（网络恢复）：

- 扫描各表脏行
- 有 books 脏 → 书架也带 `dirty_only`（只推成员变更，不做全量 shelf pull）
- 进度/笔记只推

书架脏位只能在**单条** add/delete 推送成功时清除，禁止整源盲清。

---

## 用法

```lua
local Sync = require("book.sync")

-- 面板「同步」或源全量刷新
local handle = Sync.runAsync(source, {
    force = true,           -- 传给 syncBooksAsync
    -- dirty_only = true,   -- 网络恢复 / 关书后重试
    -- skip_books = true,   -- 跳过书架域
}, function(summary, err)
    -- summary.domains.books / progress / notes / stats
    -- summary.pulled / pushed / hidden / conflicts
end)
handle.cancel()

-- main.onNetworkConnected
Sync.retryDirtyAsync()
```

源实现最小集合：

```lua
function Source:syncBooksAsync(opts, cb) … end
function Source:syncProgressAsync(opts, cb)
    return require("book.progress").syncAsync(self, opts, cb)
end
function Source:syncNotesAsync(opts, cb)
    return require("book.note").syncAsync(self, opts, cb)
end
function Source:syncStatsAsync(opts, cb)
    return require("book.stats").syncAsync(self, opts, cb)
end
```

### 注意

- 禁止在编排层对进度/笔记静默 `upsertRemote` 抹平冲突。
- 基类 `onEvent("network_connected")` 不再推脏——避免与 `retryDirtyAsync` 双通道。
- 取消后回调静默丢弃；调用方不要假设一定收到 `cb`。
