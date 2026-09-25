# xray/ — 阅读实体

路径：[`book.koplugin/xray/`](../../book.koplugin/xray/)。表：[`../db/xray_entities.md`](../db/xray_entities.md)。

从当前阅读上下文用 AI 抽人物 / 地点 / 专有名词，落本地库，阅读页标记与查询。**仅本地，不进四域同步。**

## 设计

| 文件 | 作用 |
|---|---|
| `fetch.lua` | 综合拉取 / 选词补全（调 `ai`） |
| `prompts.lua` / `context.lua` | 提示词与阅读上下文拼装 |
| `store.lua` | 实体合并（`mergeEntities`）与 prompt 快照（`promptSnapshot`），不碰库 |
| `db/xray.lua` | 读写 `xray_entities`（`list` / `upsert` / `replace`） |
| `marks.lua` | 文中标记 |
| `kinds.lua` | character / location / term |
| `ui.lua` | 阅读侧入口 |

抽取结果要能在正文里 grounding（名称至少出现在上下文中），过短或未出现的丢掉。

## 用法

```lua
local Fetch = require("xray.fetch")

-- 综合拉取；已有数据且非 force 时直接回缓存
Fetch.comprehensive(ui, identity, { force = false }, function(result, err) end)

-- 选词查实体：本地别名命中免请求，否则 AI 补全并落库
Fetch.lookupWord(ui, identity, "…", function(item, err) end)

-- 查询已存实体
local rows = require("db.xray").list(source_id, stable_id, kind)  -- kind 可省略
```

阅读 UI 经 `xray.ui` / marks 展示；需先配置 AI。依赖表见 db 文档。
