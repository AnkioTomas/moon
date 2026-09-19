# scrape/ — 元数据刮削

路径：[`book.koplugin/scrape/`](../../book.koplugin/scrape/)。

给**允许刮削的源**（通常仅 `local`，`capabilities.scrape`）搜豆瓣/微信读书元数据，写回 books 并下封面。

## 设计

```text
用户确认书名 → search → 选结果 → BookDB.upsertLocal + 封面落盘 → 回调刷新 UI
```

| 文件 | 作用 |
|---|---|
| `ui.lua` | 对话框流程 |
| `search.lua` | 聚合搜索 |
| `douban.lua` / `weread.lua` | 各站解析 |
| `results.lua` | 结果列表 UI |

入口必须先过 `SourceCapabilities.supportsScrape(source)`；不支持则不要显示按钮。  
封面先写 `.part` 再 rename，避免半截图被读到。

## 用法

```lua
local ScrapeUI = require("scrape.ui")

if SourceCapabilities.supportsScrape(source) then
    ScrapeUI.start(book, function(ok)
        -- 刷新详情/列表
    end)
end
```

写库用 `upsertLocal`（`deleted=0`，`sync_status=0`），不要走远端 upsert 路径盖掉本地脏元数据语义。
