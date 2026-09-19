# book.progress — 阅读进度

代码：[`book/progress.lua`](../../book.koplugin/book/progress.lua)。表：[`pending_progress`](../db/pending_progress.md)。

## 设计

一书一条本地进度真源，带 `sync_status`。传输层 `ProgressPosition` **不含**脏标记——脏只属于落库行。

```text
阅读中  → Progress.save → ProgressDB.upsert(sync_status=0) → 有网则 push
开书    → Progress.pull → 源 getProgressAsync → 对比 → 冲突 ConfirmBox
关书/脏 → syncAsync(dirty_only) 只推；禁止立刻回拉（远端收敛延迟会盖新值）
```

`updated_at` 用进程内 `nextRevision()`（`max(os.time(), last+1)`），避免同一秒多次写入撞号。`markSynced` 带乐观锁：推送期间若本地又更新，不会被误标已同步。

远端写入：

| API | 行为 |
|---|---|
| `ProgressDB.upsertRemote` | 本地已脏（status=0）则**整行跳过** |
| `ProgressDB.adoptRemote` | 用户选云端，无条件覆盖脏行 |
| `ProgressDB.markSynced` | push 成功且 `updated_at` 匹配 |

跳转落盘只写打开中的 `ui.doc_settings`。另开 `DocSettings:open` 写盘会在关书 flush 时被 ReaderUI 那份整体覆盖。

冲突：会话级 `asked_conflicts`，同一本书一次会话只问一次；真关书 `clearConflicts()`。

---

## 用法

```lua
local Progress = require("book.progress")

-- 从会话快照取当前位置（上报 / 顶栏）
local pos = Progress.position(snapshot)
local frac = Progress.fraction(snapshot)

-- 开书（Session 调用）
Progress.pull(snapshot)
-- 内部：有网 → getProgressAsync → 与本地比
-- 差 ≥1% → ConfirmBox：用云端 / 用本地（本地则 dirty push）

-- 阅读中或关书前落盘
Progress.save(snapshot, function(ok) end)

-- 源侧编排入口（book.sync / 面板）
Progress.syncAsync(source, { identity = identity, dirty_only = true }, cb)

-- 真关书
Progress.clearConflicts()
```

定位：

```lua
-- rolling：先 isXPointerInDocument，再 gotoXPointer
-- paging：总页数一致才 gotoPage
-- 成功后 saveDocSettings(ui, pct) 写 sidecar
```

按章选起始章（源侧 `chapter.lua`）：只读 `pending_progress`（有 `chapter_idx` 或 `fraction>0`），再回落远端；已无 `books.last_chapter_idx`。

### 注意

- 编排层对进度域永远 `dirty_only`（见 [`sync`](sync.md)）。
- `fraction>=1` 可抬 `books.read_state`，但不写 books 进度列。
- 换源/换版后旧 XPointer 必须先校验，否则会把人扔飞。
