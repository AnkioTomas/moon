# book.progress — 阅读进度

代码：[`book/progress.lua`](../../book.koplugin/book/progress.lua)。表：[`pending_progress`](../db/pending_progress.md)。

## 设计

一书一条本地进度真源，带 `sync_status`。传输层 `ProgressPosition` **不含**脏标记——脏只属于落库行。

```text
关书/suspend → Progress.save → ProgressDB.upsert(sync_status=0) → 源 syncProgressAsync(dirty_only)
开书        → Progress.pull → 源 getProgressAsync（不预判在线，失败只记日志）
              页级源：同一 spine 内远端元素更靠后 → 采纳远端；跨 spine 分歧 → 弹窗让用户选
              首次打开（本地无进度行）且云端确有进度 → 直接 adoptRemote + 跳转，不弹窗
关书/脏     → 先 getProgressAsync 比对：云端更靠后/已读完 → 当场弹窗让用户选；否则推本地。
              批量重连同规则。
```

> **本地位置以阅读器实时 locator 为准**，不是 `pending_progress` 行：行可能落后于阅读器（历史遗留或外部改写），
> 以行为准会把「本机与云端不同章」误判成同位置而永不收敛。
>
> **分歧就在发现的那一刻弹窗**：开书发现、关书推送前发现，都会弹「本地/云端」，绝不静默跳转、绝不静默改本地，
> 也不把分歧留到下次开书。用户手动读到别的章节，不能被云端位置拽走。（真实事故：Kavita「罪与罚」网页端读到第七节、
> 本地停在第三节——先是无同步无冲突框，改后又每次开书被拽回第七节。）

`updated_at` 用进程内 `nextRevision()`（`max(os.time(), last+1)`），避免同一秒多次写入撞号。`markSynced` 带乐观锁：推送期间若本地又更新，不会被误标已同步。

远端写入：

| API | 行为 |
|---|---|
| `ProgressDB.upsertRemote` | 本地已脏（status=0）则**整行跳过** |
| `ProgressDB.adoptRemote` | 用户选云端，无条件覆盖脏行 |
| `ProgressDB.markSynced` | push 成功且 `updated_at` 匹配 |

跳转落盘只写打开中的 `ui.doc_settings`。另开 `DocSettings:open` 写盘会在关书 flush 时被 ReaderUI 那份整体覆盖。

冲突：会话级 `asked_conflicts`，同一本书一次会话只问一次；真关书 `clearConflicts()`。
首次打开：本地无 `pending_progress` 行时没有可冲突的进度，云端进度非零则直接采纳并跳转（不写 `asked_conflicts`、不弹框）；云端为零值/首页则不动。
页级源（Kavita）：冲突基准是 **spine 序号 + spine 内元素路径，绝不用百分比**（Kavita 的 % 按 spine 算、进入 spine 即跳变）。以下规则只对设了 `meta.page_level` 的源（当前只有 Kavita）生效。
- **跨 spine**（本地/云端不同章）→ 弹 `askProgressConflict` 让用户选：选云端则采纳并跳转，选本地则 `force` 推本地收敛。
- **同 spine**：远端元素更靠后/已读完 → 采纳远端；否则保留本地（脏则推）。
开书/关书都会触发这套判定：开书 `pull`；关书/suspend 推送前 `getProgressAsync` 比对，云端更靠后 → **当场弹窗**（不等下次开书），本地不落后才推。用户在弹窗选「本地」时用 `force` 跳过比对直接推，避免又弹同一次。
批量重连（无 identity）：冲突**只对当前正在阅读的那本弹一次**，其余**留脏不推**（不覆盖云端），等用户下次读到由开书流程处理。
手动按钮（参考 KOReader kosync 的 Push/Pull，仅 Kavita 可用、`always_visible` 恒常显示）：
- 「推送进度」→ `Progress.push(snapshot)`：先 `save` 落盘当前阅读位置，再 `force` 推本地到云端（覆盖远端，不比对）。
- 「拉取进度」→ `Progress.pull(snapshot, { manual = true })`：拉云端收敛；冲突弹同一弹窗，无冲突/离线/无远端都给出提示。manual 模式无视 `asked_conflicts` 会话去重。

重入合并：`syncAsync` 以 `source.id` + `stable_id`（整源为 `all`）+ `chapter_idx` + 模式（`dirty` / `full`）为键，完全相同的并发请求共用一次执行、各自收到回调；不同书或不同模式各自执行。

---

## 用法

```lua
local Progress = require("book.progress")

-- 从会话快照取当前位置（上报 / 顶栏）
local pos = Progress.position(snapshot)

-- 开书（Session 调用）
Progress.pull(snapshot)
-- 内部：getProgressAsync → 与本地实时位置比（离线失败只记日志）
-- 首次打开且云端有进度 → 直接采纳并跳转
-- 页级源：同一 spine 内远端更靠后 → 采纳并跳转；跨 spine → 弹 ConfirmBox 让用户选

-- 关书 / suspend 落盘（Session.syncReading 调用；翻页不 save）
Progress.save(snapshot, function(ok) end)

-- 源侧编排入口（book.sync / 面板）
Progress.syncAsync(source, { identity = identity, dirty_only = true }, cb)
-- 用户在冲突弹窗选「本地」时用 force=true：跳过比对直接推本地收敛
Progress.syncAsync(source, { identity = identity, dirty_only = true, force = true }, cb)

-- 手动推送（阅读页快捷动作「推送进度」，仅 Kavita 可见）
Progress.push(snapshot)

-- 手动拉取（阅读页快捷动作「拉取进度」，仅 Kavita 可见）
Progress.pull(snapshot, { manual = true })
-- 有冲突 → 弹「本地/云端」；无冲突 → InfoMessage「进度已是最新」；离线/无远端 → 提示
-- 与 pull 的差别：无视 asked_conflicts 会话去重，每次点都重新拉、重新判

-- 真关书
Progress.clearConflicts()
```

定位：

```lua
-- rolling：先 isXPointerInDocument，再 ui.rolling:onGotoXPointer
-- paging：总页数一致才 gotoPage
-- 成功后 saveDocSettings(ui, pct) 写 sidecar
```

按章选起始章（源侧 `chapter.lua`）：只读 `pending_progress`（有 `chapter_idx` 或 `fraction>0`），再回落远端；已无 `books.last_chapter_idx`。

### 注意

- 编排层对进度域永远 `dirty_only`（见 [`sync`](sync.md)）。
- `fraction>=1` 可抬 `books.read_state`，但不写 books 进度列。
- 换源/换版后旧 XPointer 必须先校验，否则会把人扔飞。
