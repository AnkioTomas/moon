# source.base — 数据源基类

代码：[`source/base.lua`](../../book.koplugin/source/base.lua)（含 `BookSource` / `SourceCapabilities` 等注解与能力表运行时）。

## 设计

各适配器继承本类，**只覆盖真实支持的传输**。四类同步里不支持的方向异步返回 `skipped`，不能伪造成功数据。

默认查询全部读 `book.catalog`：桌面先渲染本地，再由后台同步回调刷新。

桌面生命周期里基类会节流同步书架/统计（默认 5 分钟）。`network_connected` **不**推脏——脏重试由 `book.sync.retryDirtyAsync` 单通道负责。

书架语义：

- 远端快照 → `Store.reconcile`（pulled）
- 本地脏成员经 add/delete 上行（pushed）
- 本地删除只标 `deleted`；同步时推云端真删，成功后 `finalizeDeleted`

---

## 用法

### 继承骨架

```lua
local SourceBase = require("source.base")
local M = {}
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

function M.meta()
    return { id = "my", name = _("我的源"), type = "book" }  -- 或 "chapter"
end

function M.new()
    return setmetatable({
        id = "my", name = …, type = …,
        -- client / cfg …
    }, Source)
end

function Source:capabilities()
    return {
        search = true,
        refresh = false,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = false,
        -- cacheAllChaptersAsync = function(...) … end,  -- 可选
    }
end

function Source:configured()
    return self._client:configured()
end

function Source:syncBooksAsync(opts, cb) … end
function Source:openBookAsync(identity, opts, cb) … end
-- 按需：get/putProgress、notes、stats、loadToc、prefetch、coverRequest、deleteBookAsync

return M
```

### onEvent

```lua
function Source:onEvent(event, payload)
    SourceBase.onEvent(self, event, payload)  -- 保留桌面节流同步
    if event == "page_changed" then
        -- payload: identity, page, total_pages, percent
    elseif event == "book_info_request" then
        -- 拉最新详情 → Store.rememberMany → payload.refresh()
    end
end
```

| 事件 | 基类默认 |
|---|---|
| `home_open` / `desktop_resume` | syncStats（内部节流）+ syncBooks（`BOOKS_REFRESH_INTERVAL` 节流） |
| `desktop_open` | syncStats（内部节流）+ 每次 syncBooks |
| `library_refresh_request` | `force` 同时刷统计与书架 |
| `network_connected` | 空 |
| `reader_open` / `fm_open` / `document_close` / `suspend` / `chapter_changed` / `page_changed` / `book_info_request` | 空 |

### 默认本地查询（可不覆盖）

```lua
source:recentBooksAsync(limit, cb)
source:listLibraryAsync(opts, cb)
source:filtersAsync(cb)
source:readingInsightAsync(cb)
```

### 异步约定

```lua
-- 所有 XxxAsync 可取消时：
return { cancel = function() cancelled = true; job:cancel() end }

-- 不支持：
return SourceBase.syncBooksAsync(self, opts, cb)  -- 内部 skipped
```

回调里必须检查：桌面是否 Destroy、`desktop.source` 是否仍是自己、请求 token 是否过期。

### 注意

- `capabilities` 是「用户能用的功能」，不是「模块里有没有函数」。UI 用 `SourceCapabilities.supportsScrape/Edit/StatsPull`。
- 默认 `deleteBookAsync` 会 nextTick 返回「不支持」；要删书请覆盖。
