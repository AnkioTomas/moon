--[[--
书城 Tab：浏览目录。
  local / webdav 使用全局 Z-Library；自带书城能力的源仍走 source.listStoreAsync。

布局（同 Library.build）：
  +-----------------------------------------------+
  | [🔍搜索] [清除]                     共N       |
  | +----+ +----+ +----+ +----+                   |
  | |封面| |封面| |封面| |封面|                   |
  | |书名| |书名| |书名| |书名|                   |
  | +----+ +----+ +----+ +----+                   |
  |  |«  ‹   Page N of M   ›  »|                  |
  +-----------------------------------------------+

@module koplugin.book.ui.store
--]]

local Library = require("ui.desktop.library")
local BookStore = require("book.store")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Store = {}
local MAX_RESULTS = 200

--- 从已加载结果中切出当前 UI 页。
---@param desktop table
---@return table
function Store.pageBooks(desktop)
    local all = desktop._store_books or {}
    local page_size = desktop.store_page_size or desktop.page_size or 1
    local first = ((desktop.store_page or 1) - 1) * page_size + 1
    local books = {}
    for i = first, math.min(#all, first + page_size - 1) do
        books[#books + 1] = all[i]
    end
    return books
end

--- 复用图书馆网格构建书城页。
---@param ctx table
---@param state table
---@param opts table|nil
---@return table
function Store.build(ctx, state, opts)
    opts = opts or {}
    opts.loading_text = opts.loading_text or _("加载中…")
    opts.empty_text = opts.empty_text or _("书城暂无内容")
    opts.search_only = true
    opts.on_search = opts.on_search or function()
        if ctx.desktop then Store.showSearch(ctx.desktop) end
    end
    opts.on_clear = opts.on_clear or function()
        if ctx.desktop then Store.applySearch(ctx.desktop, "") end
    end
    return Library.build(ctx, state, opts)
end

--- 应用书城搜索，搜索词与图书馆筛选状态分开保存。
---@param desktop table
---@param query string|nil
function Store.applySearch(desktop, query)
    if desktop._store_fetch_cancel then
        desktop._store_fetch_cancel:cancel()
        desktop._store_fetch_cancel = nil
    end
    desktop.store_search = query and query ~= "" and query or nil
    desktop.store_page = 1
    desktop.store_total = 0
    desktop._store_books = nil
    desktop._store_state = nil
    desktop.tab = "store"
    desktop:rebuild()
end

--- 弹出书城搜索框。
---@param desktop table
function Store.showSearch(desktop)
    Library.showSearch(desktop, function(query)
        Store.applySearch(desktop, query)
    end, desktop.store_search)
end

--- 同步书城 page_size（与图书馆网格容量一致）。
---@param desktop table
---@return number
function Store.syncPageSize(desktop)
    Library.syncPageSize(desktop)
    desktop.store_page_size = desktop.page_size
    return desktop.store_page_size
end

--- 计算书城总页数。
---@param desktop table
---@return number
function Store.pages(desktop)
    local ps = desktop.store_page_size or desktop.page_size or 1
    local total = desktop.store_total or 0
    return math.max(1, math.ceil(total / ps))
end

--- 跳转到书城指定页并重建。
---@param desktop table
---@param page number
function Store.gotoPage(desktop, page)
    page = tonumber(page) or 1
    local pages = Store.pages(desktop)
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    if page == desktop.store_page and desktop._store_state then
        return
    end
    desktop.store_page = page
    desktop._store_state = desktop._store_books and { books = Store.pageBooks(desktop) } or nil
    desktop:rebuild()
end

--- 异步拉取书城列表。
---@param desktop table
function Store.fetch(desktop)
    if desktop._store_fetch_cancel then
        desktop._store_fetch_cancel:cancel()
        desktop._store_fetch_cancel = nil
    end

    Store.syncPageSize(desktop)
    local source = desktop.source
    local generation = desktop.source_generation or 0
    local search = desktop.store_search or ""

    --- 写入错误状态；失败结果不缓存。
    ---@param err string
    local function fail(err)
        if desktop._closed or desktop.tab ~= "store" then return end
        desktop._store_books = nil
        desktop.store_total = 0
        desktop._store_state = { books = {}, err = err }
        desktop:rebuild()
    end

    if not source or not source.configured or not source:configured() then
        fail(_("请先在设置里配置当前数据源"))
        return
    end
    local backend = type(source.importBookAsync) == "function" and require("zlib.init") or source
    if not backend.listStoreAsync then
        fail(_("当前数据源不支持书城"))
        return
    end
    desktop._store_fetch_cancel = backend:listStoreAsync({
        page = 1,
        page_size = MAX_RESULTS,
        search = search,
    }, function(res, err)
        if desktop._closed or desktop.tab ~= "store"
            or desktop.source ~= source or (desktop.source_generation or 0) ~= generation
            or (desktop.store_search or "") ~= search then
            return
        end
        desktop._store_fetch_cancel = nil
        if not res then
            fail(err or _("加载失败"))
            return
        end
        local books = {}
        for i = 1, math.min(#(res.data or {}), MAX_RESULTS) do
            books[#books + 1] = res.data[i]
        end
        if backend == source then
            BookStore.rememberMany(books)
        end
        desktop._store_books = books
        desktop.store_total = #books
        local pages = Store.pages(desktop)
        if (desktop.store_page or 1) > pages then desktop.store_page = pages end
        desktop._store_state = { books = Store.pageBooks(desktop) }
        desktop:rebuild()
    end)
end

--- Desktop rebuild 入口。
---@param desktop table
---@return table
function Store.page(desktop)
    local prev_ps = desktop.store_page_size
    Store.syncPageSize(desktop)
    if prev_ps and prev_ps ~= desktop.store_page_size then
        desktop._store_state = nil
        local pages = Store.pages(desktop)
        if (desktop.store_page or 1) > pages then
            desktop.store_page = pages
        end
    end
    local state = desktop._store_state
    if not state and desktop._store_books then
        state = { books = Store.pageBooks(desktop) }
        desktop._store_state = state
    end
    if not state then
        UIManager:nextTick(function()
            if desktop._closed or desktop.tab ~= "store" then return end
            Store.fetch(desktop)
        end)
    end
    return Store.build(desktop:ctx(), state or {}, {
        page = desktop.store_page,
        pages = Store.pages(desktop),
        total = desktop.store_total or 0,
        loading_text = _("加载中…"),
        empty_text = _("书城暂无内容"),
        on_prev = function()
            Store.gotoPage(desktop, (desktop.store_page or 1) - 1)
        end,
        on_next = function()
            Store.gotoPage(desktop, (desktop.store_page or 1) + 1)
        end,
        on_first = function()
            Store.gotoPage(desktop, 1)
        end,
        on_last = function()
            Store.gotoPage(desktop, Store.pages(desktop))
        end,
    })
end

return Store
