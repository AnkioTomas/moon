# book.stats — 阅读统计

代码：[`book/stats.lua`](../../book.koplugin/book/stats.lua)。表：[`reading_stats`](../db/reading_stats.md)。

## 设计

自采集阅读时长，不依赖 KOReader 统计插件。身份按 `(source_id, stable_id)` 隔离，上报走**属主源**的 `syncStatsAsync` / `pushStatsAsync`。

内存里维护当前页计时会话：

- `onPage`：先结清上一页，再换页
- 时长 `<1s` 或 `page<1` → 丢弃
- 落库：`record_type=page`，`sync_status=0`

推送批次 `PUSH_BATCH=200`。是否从远端拉合成桶看源能力 `stats_pull`。有云端 day 桶的日期以云端为准，避免双计（细节见 db 文档）。

worker 子进程禁止写本表。

---

## 用法

```lua
local Stats = require("book.stats")

-- ReaderReady
Stats.start(snapshot)

-- 翻页（Session.onPageChanged）
Stats.onPage(snapshot)

-- 关书 / suspend：结清并可选上报
Stats.stop(function()
    source:syncStatsAsync({ dirty_only = true }, cb)
end)

-- 全量或编排
Stats.syncAsync(source, opts, cb)
Stats.push(source, done)
Stats.pull(source, done)   -- 仅 stats_pull=true 的源有意义
```

桌面洞察读本地：

```lua
require("book.catalog").readingInsightAsync(source_id, cb)
-- 先展示；源后台 syncStats 后再刷新
```

### 注意

- `main.lua` 不要直接调统计同步——由 Session / `book.sync` / 源 `onEvent` 触发。
- 换源后旧书统计仍属旧 `source_id`，用属主源推，不要推到 current。
- `stats_pull=false` 时 pull 应 `skipped`，不要伪造空成功后清空本地。
