# book.catalog — 本地书库查询

代码：[`book/catalog.lua`](../../book.koplugin/book/catalog.lua)。

## 设计

本地目录的**唯一读入口**：books 提供列表，`pending_progress` 提供最近阅读与进度百分比，`reading_stats` 提供洞察。  
远端源只负责 `sync*` 写库；读路径与 HTTP 协议解耦。

`library_mixed` 打开时，列表/筛选/最近/洞察跨 `Registry.listEnabled()` 聚合；**每本书仍带真实 `source_id`**，打开走属主源，不会因为混合视图串源。

列表进度：`COALESCE(pending_progress.fraction * 100, 0)`。books 表已无 `percent` 列。

---

## 用法

```lua
local Catalog = require("book.catalog")

-- SourceBase 默认实现就是转调这些：
Catalog.listLibraryAsync(source_id, {
    search = "关键词",
    category = "…",
    page = 1,
    page_size = 24,  -- 缺省 24，须与网格容量一致
}, function(data, err)
    -- data: BookListResult { data = Book[], … }
end)

Catalog.recentBooksAsync(source_id, 12, cb)
Catalog.filtersAsync(source_id, cb)           -- 分类/系列/已读计数
Catalog.readingInsightAsync(source_id, cb)    -- 统计页

-- 同步版（无网络）
local rows = Catalog.recentShelf(source_id, limit)
local rows = Catalog.recentBooks(source_id, limit)

-- 混合库：传入的 preferred_id 仍用于「当前源」展示，scope 内部展开
local scope = Catalog.libraryScope(preferred_id)
```

UI 侧：

```lua
-- 先画本地结果
Catalog.listLibraryAsync(id, opts, function(data, err)
    if desktop.lifecycle.state == "Destroy" then return end
    if desktop.source.id ~= expected_id then return end  -- 或用请求代次
    self:render(data)
end)
-- 再后台 syncBooksAsync，完成后 onEvent("home_refresh") 再拉一次
```

### API 要点

| API | 说明 |
|---|---|
| `libraryScope(preferred_id)` | mixed → 启用源 id 列表；单源 → 字符串（SQL `=`） |
| `toList(rows, count, source_id)` | DB 行 → `BookListResult` |
| `toInsight(...)` | 统计汇总 → 洞察结构 |
| `formatDuration(seconds)` | 纯 Lua 模板，不依赖 `ffi/util.template`（测试兼容） |

### 注意

- 异步回调必须检查桌面是否 Destroy、源是否已切换、请求是否过期。
- 混合列表里点书，用行上的 `book.source_id` 打开，不要假定等于当前 Tab 源。
