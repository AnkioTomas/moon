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
| `record_type` | `page` / `page_rollup` / `day` / `book` / `total` / `book_total` / `book_day` | 采集与 pull | 汇总过滤 | 账户合成 = day/total；单书云端 = book_total（累计）/ book_day（按日），stable_id 为真实书 id；`book` 为旧版周排行 `__wr:week:*`，已不再写入，每次 pull 整段清除 |
| `page` | 页号 | page 事件 | | rollup/合成常为 0 |
| `start_time` | 事件或桶起点（Unix） | 同上 | 时间窗 / 排序 | |
| `duration` | 秒 | 同上 | 汇总 | `add` 要求 `>0` |
| `total_pages` | 总页辅助 | 可选 | | DEFAULT 0 |
| `chapter_idx` / `chapter_fraction` | 章上下文 | 可选 | 上报 | 可空 |
| `sync_status` | 0 待上传 / 1 已同步 | add(synced) / markSynced | unsynced | CONFLICT 取 `MAX` |
| `event_count` | 压缩事件数 | rollup | | DEFAULT 1 |
| `last_time` | rollup：桶内最后时间；day / book_day：拉取时间 | rollup / pull | 合并口径 | DEFAULT 0（旧版拉取的 day 为 0） |

## 数据流

| 场景 | 路径 |
|---|---|
| 翻页计时 | `book.stats` → `StatsDB.add`（`record_type=page`，`sync_status=0`） |
| 小时压缩 | 旧 page → `page_rollup`，再删过期已同步 page |
| 上报 | `unsyncedBySource` → 属主源 `syncStatsAsync` / `pushStatsAsync` → `markSynced(ids)` |
| 下行 | `StatsDB.replaceSynced`：先按策略清合成行，再 `add(..., true)` |
| 单书明细 | 微信 `pullStatsAsync` 末尾：书架 `bookProgress.readingTime` 与本地 `book_total` 不同的书（每轮 ≤20 本，最近更新优先）→ Eink `/book/readinfo` → `book_total`（=书架 readingTime，start_time=拉取时间）+ `book_day`（`readDetail.data`）；经 `replace.books` 按 stable_id 精确整本替换 |

## 同步语义

有脏队列；`retryDirtyAsync` 会扫本表。

Pull 铁律（注释写进代码的事故教训）：

1. **只删合成行**（`record_type IN ('day','book','total')`）。本地 page 推成功后也是 `sync_status=1`，按 status 全删会吞用户历史。
2. **只删回包时间窗**。回包通常只覆盖近一个月；删整源等于每次同步抹掉更早数据。
3. `replace.mode == "all_synced"` 存在于 API，但属于危险路径；默认路径走 `deleteSyntheticInRange`。

合并口径统一一条：**有云端值 = 云端 + 本地（`sync_status=0` 或 `start_time ≥ 拉取时间`）；否则只有本地**。快照前已上传的本地时长已含在云端里，不再加。

- 账户按日（日历 / 账单总时长）：`day` 桶，拉取时间取本源 `MAX(last_time)`；为 0（旧版拉取）时只补未上传的。
- 单书累计（`summaryByBook`）：`book_total`，拉取时间 = 其 `start_time`。
- 单书按日（`dailyByBook` / `dailyBooksBySource` / `periodBooks` / `periodSummary` 书数）：`book_day`，按书取拉取时间，共用 `bookDays` CTE。
- 云端单书按日求和本就不等于累计（零碎时长被丢），两者不互推。
- `book_total` / `book_day` 不在账户 pull 的区间清理范围内，也不进账户日历。

## 与其他表关系

- 身份对齐 [`books`](books.md) 的 `(source_id, stable_id)`（合成行 stable_id 可能带前缀，查询时过滤）
- 与进度/注解无 FK

## 不变量 / 地雷

1. 身份唯一索引必须含 `record_type`（v1 漏了会导致压缩撞删 page）。  
2. 汇总查询不能把云端行当本地行直接相加，否则账单翻倍：账户按日只认 `day` + 本地逐页，按书一律走 `bookDays` 合并。  
3. `replaceSynced` 空 rows 时 **什么都不删**（与笔记「宁可漏云端删除」同立场）。  
4. `replace.books` 必须按 stable_id **精确**删除，不能用 LIKE 前缀（书 id 可能互为前缀，如 `4` / `42`）。

## 代码入口

- [`book.koplugin/db/stats.lua`](../../book.koplugin/db/stats.lua)
- [`book.koplugin/book/stats.lua`](../../book.koplugin/book/stats.lua)
- 源上报：`SourceBase:syncStatsAsync` / 各源 `pushStatsAsync`
