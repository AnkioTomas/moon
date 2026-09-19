# reading_stats

## 职责

阅读时长自采集落库：本地逐页事件、小时压缩桶，以及云端日/书/全源合成桶；按 `source_id` 隔离，带 `sync_status` 供上报。

## 非职责

- 不依赖 KOReader 自带统计插件
- 不存进度位置、注解、书架成员
- 子进程 / `workers.job` **禁止**碰本表（主进程落库）

## 主键 / 索引

- **PK**：`id INTEGER AUTOINCREMENT`（行号，供 `markSynced`）
- **唯一身份**：`idx_reading_stats_identity_v2 (source_id, stable_id, record_type, page, start_time, duration)`
- **rollup 桶**：`idx_reading_stats_rollup_bucket (source_id, stable_id, record_type, start_time) WHERE record_type='page_rollup'`
- `idx_reading_stats_time (source_id, start_time)`

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `id` | 行号 | AUTOINCREMENT | unsynced / markSynced | |
| `source_id` | 源隔离 | add / replaceSynced | 全查询 | |
| `stable_id` | 书身份；合成桶可用约定前缀 | 同上 | 同上 | 与 books.stable_id 对齐；云端合成行另有前缀约定 |
| `record_type` | `page` / `page_rollup` / `day` / `book` / `total` | 采集与 pull | 汇总过滤 | 合成 = day/book/total |
| `page` | 页号 | page 事件 | | rollup/合成常为 0 |
| `start_time` | 事件或桶起点（Unix） | 同上 | 时间窗 / 排序 | |
| `duration` | 秒 | 同上 | 汇总 | `add` 要求 `>0` |
| `total_pages` | 总页辅助 | 可选 | | DEFAULT 0 |
| `chapter_idx` / `chapter_fraction` | 章上下文 | 可选 | 上报 | 可空 |
| `sync_status` | 0 待上传 / 1 已同步 | add(synced) / markSynced | unsynced | CONFLICT 取 `MAX` |
| `event_count` | 压缩事件数 | rollup | | DEFAULT 1 |
| `last_time` | 桶内最后时间 | rollup | | DEFAULT 0 |

## 数据流

| 场景 | 路径 |
|---|---|
| 翻页计时 | `book.stats` → `StatsDB.add`（`record_type=page`，`sync_status=0`） |
| 小时压缩 | 旧 page → `page_rollup`，再删过期已同步 page |
| 上报 | `unsyncedBySource` → 属主源 `syncStatsAsync` / `pushStatsAsync` → `markSynced(ids)` |
| 下行 | `StatsDB.replaceSynced`：先按策略清合成行，再 `add(..., true)` |

## 同步语义

有脏队列；`retryDirtyAsync` 会扫本表。

Pull 铁律（注释写进代码的事故教训）：

1. **只删合成行**（`record_type IN ('day','book','total')`）。本地 page 推成功后也是 `sync_status=1`，按 status 全删会吞用户历史。
2. **只删回包时间窗**。回包通常只覆盖近一个月；删整源等于每次同步抹掉更早数据。
3. `replace.mode == "all_synced"` 存在于 API，但属于危险路径；默认路径走 `deleteSyntheticInRange`。

按天展示：有云端 `day` 桶的日期以云端为准，避免与本地 page 双计。

## 与其他表关系

- 身份对齐 [`books`](books.md) 的 `(source_id, stable_id)`（合成行 stable_id 可能带前缀，查询时过滤）
- 与进度/注解无 FK

## 不变量 / 地雷

1. 身份唯一索引必须含 `record_type`（v1 漏了会导致压缩撞删 page）。  
2. 汇总查询必须排除合成行（`NOT_SYNTHETIC`），否则账单翻倍。  
3. `replaceSynced` 空 rows 时 **什么都不删**（与笔记「宁可漏云端删除」同立场）。

## 代码入口

- [`book.koplugin/db/stats.lua`](../../book.koplugin/db/stats.lua)
- [`book.koplugin/book/stats.lua`](../../book.koplugin/book/stats.lua)
- 源上报：`SourceBase:syncStatsAsync` / 各源 `pushStatsAsync`
