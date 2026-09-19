# books

## 职责

一书一行：跨源身份、书架成员（软删）、展示元数据，以及目录/排版的本地缓存。

## 非职责

- 不存章节 path 映射（见 [`chapters`](chapters.md)）
- 不存进度真源与定位字段（见 [`pending_progress`](pending_progress.md)）
- 不存注解 / 统计事件 / X-Ray 实体

## 主键 / 索引

- **PK**：`(source_id, stable_id)`
- `idx_books_md5 (source_id, md5)` — 本地源改名识别
- `idx_books_path (path)` — 整本文件身份解析
- `idx_books_library (source_id, deleted, stable_id)` — 书架列表
- `idx_books_sync (source_id, sync_status)` — 脏队列

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `source_id` | 源标识 | 登记/对账 | 全链路身份 | 与 `stable_id` 组成跨源身份 |
| `stable_id` | 源内稳定 ID | 同上 | 同上 | local 源即文件绝对路径 |
| `md5` | 内容 partialMD5 | 本地扫盘/`upsert` | 改名联动 | 可空 |
| `title` / `authors` / `category` / `series` / `intro` / `cover` | 展示元数据 | `upsert` / `upsertRemote*` / `upsertLocal` | catalog / UI | `sync_status=0` 时远端 upsert **不覆盖** 前五字段（cover 仍可更新） |
| `inserted_at` | 本行首次写入时间 | INSERT | 列表「最近加入」排序 | UPDATE 不改；`0` = 仅身份行 |
| `path` | 整本物理路径 | `touchPath` / 清路径 | `getByPath` | 身份解析入口之一 |
| `deleted` | `0` 在架有效 / `1` 软删或非成员 | reconcile / `setLibraryMembership` / upsert | catalog | 列表过滤 `deleted=0` |
| `sync_status` | `0` 待上传 / `1` 已同步 | 本地写=0；远端收敛=1 | unsynced / sync | 成员与展示共用 |
| `reader_prefs` | 全书排版 JSON | `setReaderPrefs` | 开书注入 sidecar | 仅本地；INSERT 时 `deleted=1` |
| `toc` / `toc_fetched_at` | 目录缓存 | `setToc` / `clearToc` | 按章会话 / 源 | 不透明 JSON；TTL 由调用方解释 |
| `read_state` | 0 可自动已读 / 1 已读 / 2 强制未读 | `setRead` / 进度完成 | 筛选与绑带 | 与 `pending_progress.fraction` 联动 |

已删除列：`percent`、`in_library`、`metadata_dirty`、`metadata_updated_at`、`is_new`、`fetched_at`。

旧库迁移：`fetched_at`→`inserted_at`；`in_library=1`→`deleted=0`，否则 `deleted=1`。旧列可残留但不再读写。

## 数据流

| 场景 | 路径 |
|---|---|
| 远端书架对账 | 源 `syncBooksAsync` → `Store.reconcile` → `BookDB.reconcile`（在架先 `deleted=1`，再 upsert 远端 `deleted=0`） |
| 本地扫盘 / 登记 | `BookDB.upsert`（`deleted=0`，`sync_status=0`） |
| 打开/下载落盘 | `Store.touch` → `touchPath`（新行 `deleted=1`，非书架成员） |
| 用户编辑 / 刮削 | `BookDB.upsertLocal`（`deleted=0`，`sync_status=0`） |
| 进度变化 | 只写 `pending_progress`；列表 JOIN `fraction*100` |
| 图书馆列表 | `BookDB.listBySource`：`deleted=0` + LEFT JOIN `pending_progress` |

## 同步语义

- 脏队列：`sync_status=0`
- **本地删除**：`deleted=1` + `sync_status=0`（书架立刻消失）；同步时推云端真删，成功后撕墓碑（`BookDB.remove`）
- **本地上架**：`deleted=0` + `sync_status=0`；同步时 `addToShelf`，成功后 `markSynced`
- 远端 upsert：本地已脏时不盖展示五字段与 `deleted`
- `retryDirtyAsync`：有 books 脏行时跑书架域且 `dirty_only`（只推删/加，禁止全量 shelf pull）；**禁止**书架成功后整源清脏——只在单条 push 成功时清

## 与其他表关系

- [`pending_progress`](pending_progress.md)：进度真源；列表 `COALESCE(p.fraction*100, 0)`
- [`chapters`](chapters.md)：章文件 path；整本仍用本表 `path`
- [`notes`](notes.md) / [`reading_stats`](reading_stats.md) / [`xray_entities`](xray_entities.md)：同身份挂靠

## 不变量 / 地雷

1. `touchPath` / `setReaderPrefs` / `setToc` 新建行必须 `deleted=1`，禁止误上架。  
2. `upsert` / `upsertLocal` 上架写 `deleted=0` 并 `sync_status=0`。  
3. 进度禁止再写回本表。

## 代码入口

- 表访问：[`book.koplugin/db/book.lua`](../../book.koplugin/db/book.lua)
- 身份 / 对账：[`book.koplugin/book/store.lua`](../../book.koplugin/book/store.lua)
- 列表：[`book.koplugin/book/catalog.lua`](../../book.koplugin/book/catalog.lua)
- 类型：[`book.koplugin/types/book.lua`](../../book.koplugin/types/book.lua)
