# source.base — 数据源基类

代码：[`source/base.lua`](../../book.koplugin/source/base.lua)（含 `BookSource` / `SourceCapabilities` 等注解与能力表运行时）。

## 设计

各适配器继承本类，**只覆盖真实支持的传输**。四类同步里不支持的方向异步返回 `skipped`，不能伪造成功数据。

默认查询全部读 `book.catalog`：桌面先渲染本地，再由后台同步回调刷新。

基类不碰桌面：桌面打开 / 换源 / 图书馆刷新时的书架与统计同步由 [`desktop/sync.lua`](../../book.koplugin/desktop/sync.lua) 直接调 `syncBooksAsync` / `syncStatsAsync`（统计 5 分钟节流，在飞状态挂在桌面实例上）。网络恢复走 `SourceBase:onNetworkConnected`：只推本源脏行（书架、笔记、统计，进度最后），没有脏行的域不调用。

书架语义：

- 远端快照 → `Shelf.reconcile`（pulled）
- 本地脏成员经 add/delete 上行（pushed）
- 本地删除只标 `deleted`；同步时推云端真删，成功后 `BookDB.remove`

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
        cfg = require("utils.settings").getSource("my"),
    }, Source)
end

function Source:capabilities()
    return {
        scrape = false,
        edit = false,
        stats_pull = false,
    }
end

function Source:configured()
    return (self.cfg.token or "") ~= ""
end

function Source:syncBooksAsync(opts, cb) … end
function Source:openBookAsync(identity, opts, cb) … end
-- 按需：get/putProgress、notes、stats、loadToc、prefetch、coverRequest、deleteBookAsync

return M
```

### 生命周期

`onCreate` / `onSuspend` / `onResume` / `onNetworkConnected` / `onExit`，参数为插件实例；除 `onNetworkConnected`（只推本源脏行）外基类空操作。main 转给所有启用源（混合模式下都在用，要不要响应由源自己判断）；阅读中旧书的属主源可能不是当前源，阅读期收尾在 `reader/session`。

### onEvent

调用方直接对属主源调用（没有 plugin 中转）。

```lua
function Source:onEvent(event, payload)
    if event == "page_changed" then
        -- payload: identity, page, total_pages, percent
    elseif event == "book_info_request" then
        -- 拉最新详情 → Store.rememberMany → payload.refresh()
    end
end
```

事件只有 `chapter_changed` / `page_changed` / `book_meta_changed` / `book_info_request`，基类全部空操作，清单与载荷见 `SourceBase:onEvent` 注释。

### 本地查询

书库列表、筛选项、阅读洞察只读本地库，不经源：直接调 `book.catalog` 的 `listLibraryAsync(source_id, opts, cb)` / `filtersAsync(source_id, cb)` / `readingInsightAsync(source_id, cb)`。

### 异步约定

```lua
-- 所有 XxxAsync 可取消时：
return { cancel = function() cancelled = true; job:cancel() end }

-- 命中缓存 / 当场失败也必须下一帧回调（返回可取消句柄）：
return SourceBase.defer(cb, cached)

-- 不支持的同步域：
return SourceBase.skipped(cb, "reason")
```

取消后不回调；源回调里不碰桌面，过期结果的丢弃由 `desktop/sync.lua` 按请求令牌处理。

### 注意

- `capabilities` 是「用户能用的功能」，不是「模块里有没有函数」。UI 用 `SourceCapabilities.supportsScrape/Edit/StatsPull`。
- 默认 `deleteBookAsync` 本地优先删除（清缓存 + 墓碑，已连网顺手 `pushDirty`）；源只补自己的内存缓存清理。
