# pending_progress

## 职责

一书一条的**阅读进度真源**（含章内定位），并携带与远端收敛的 `sync_status`。

表名含 `pending_`，但行同时表示已同步状态；语义是「本地进度记录」，不是「仅待传队列」。

## 非职责

- 不存书架成员（[`books.deleted`](books.md)）
- 不存注解、统计时长
- 传输层 `ProgressPosition` 不含 `sync_status`（脏标记只属于落库行）
- 不回写 `books` 进度列（books 无 `percent`）

## 主键 / 索引

- **PK**：`(source_id, stable_id)`
- `idx_pending_progress_recent (source_id, updated_at DESC)` — 最近阅读

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `source_id` / `stable_id` | 书身份 | upsert* | get / unsynced / 最近阅读 | |
| `fraction` | 全书进度 **0..1** | upsert* | UI / 开书冲突 | 真源 |
| `chapter_idx` / `chapter_title` / `chapter_fraction` | 章定位 | upsert* | 按章开书 / 上报 | 可空 |
| `page` / `total_pages` | 页码定位 | upsert* | 整本模式 | 正整数或空 |
| `locator` | 文档定位串 | upsert* | 恢复阅读位置 | 可空 |
| `extra` | 源私有 JSON | upsert*（encode） | get 时 decode | 如 wechat `chapter_uid` |
| `updated_at` | 修订时间 | 本地写常用 `os.time()`；远端可能带时间 | 乐观锁 / 排序 | CONFLICT 时 `MAX(excluded, existing)` |
| `sync_status` | 0 待上传 / 1 已同步 | upsert=0；upsertRemote/adopt/markSynced=1 | unsynced / sync | |

## 数据流

| API | `sync_status` | 行为 |
|---|---|---|
| `ProgressDB.upsert` | 0 | 本地阅读 / `setRead` 抬进度 |
| `ProgressDB.upsertRemote` | 1 | 远端拉取；**若本地已是 0 则整行跳过** |
| `ProgressDB.adoptRemote` | 1 | 用户确认用云端，无条件覆盖脏行 |
| `ProgressDB.markSynced` | 1 | push 成功且 `updated_at` 匹配 |

落盘成功后：`fraction>=1` 时可能抬 `books.read_state`（不写进度缓存列）。

编排：`book.progress` → 源 `getProgressAsync` / `putProgressAsync`；关书常用 `dirty_only`。

## 同步语义

标准脏队列：`unsynced(source_id)` → push → `markSynced`。  
`book.sync.retryDirtyAsync` 会扫描本表脏行。编排层对进度域强制 `dirty_only`。

**Pull 仅开书**：`Progress.pull` 先拉后比，冲突 ConfirmBox；选本地后只 `dirty_only` 推。禁止静默 `upsertRemote` 抹平冲突。

## 与其他表关系

- [`books`](books.md)：`deleted=0` 在架；最近阅读要求在架
- 按章起始章：读本表，不读已不存在的 `books.last_chapter_idx`
- 列表进度：`COALESCE(p.fraction*100, 0)`，books 无 percent 列

## 不变量 / 地雷

1. `upsertRemote` 的 `keep_dirty` 必须在落库前判定，脏行整行跳过。  
2. `markSynced` 依赖 `updated_at` 乐观锁，避免推送期间更新被误标已同步。  
3. Schema 初始化会把「进度已满且 read_state=0」的书抬成已读。

## 代码入口

- [`book.koplugin/db/progress.lua`](../../book.koplugin/db/progress.lua)
- [`book.koplugin/book/progress.lua`](../../book.koplugin/book/progress.lua)
- 类型：[`book.koplugin/db/progress.lua`](../../book.koplugin/db/progress.lua)（`PendingProgress`）、[`book.koplugin/book/progress.lua`](../../book.koplugin/book/progress.lua)（`ProgressPosition`）
