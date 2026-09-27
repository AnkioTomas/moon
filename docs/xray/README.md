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

两阶段生成：

- **初始化**（本书库里还没有实体）：只给书名 / 作者 / 简介，让模型凭通用知识生成整本书的实体，不看进度、不避剧透、不做 grounding。模型回 `known=false`、没给出实体或书名为空时，回落到章节增量。
- **增量**（已有实体后刷新）：当前页 + 本章开头到当前页之前的正文（按目录定章首，无目录从第 1 页；CRE 用 xpointer 取区间，过长保留末尾 24000 字节）+ 已有实体快照，结果要能在正文里 grounding（名称或别名至少出现在上下文中），过短或未出现的丢掉。正文里的不同译名 / 称呼会被补进已有实体的 aliases，让页内标记能命中。
- **划词**：只取当前页 + 前 2000 字节，够判断词语即可。

description 是全书整体描述而非章节摘要：已有实体的原描述随快照发给模型，更新时在原描述基础上融合新信息后整段输出。

页内标记先取一次屏幕文字，去空白后本地粗筛出屏上真正出现的名字，只对这些名字调用 `findText` / `findAllMatches` 定位。

## 用法

```lua
local Fetch = require("xray.fetch")

-- 综合拉取；库空走通用知识初始化，已有数据且非 force 时直接回缓存，force 走章节增量
Fetch.comprehensive(ui, identity, { force = false }, function(result, err) end)

-- 选词查实体：本地别名命中免请求，否则 AI 补全并落库
Fetch.lookupWord(ui, identity, "…", function(item, err) end)

-- 查询已存实体
local rows = require("db.xray").list(source_id, stable_id, kind)  -- kind 可省略
```

阅读 UI 经 `xray.ui` / marks 展示；需先配置 AI。依赖表见 db 文档。
