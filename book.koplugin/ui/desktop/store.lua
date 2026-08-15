--[[--
书城 Tab：浏览目录（listStore）
  UI 复用 Library 网格；仅当 source.capabilities.store 时出现在底栏

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

--- 复用图书馆网格构建书城页。
---@param ctx table
---@param state table
---@param opts table|nil
---@return table
function Store.build(ctx, state, opts)
    opts = opts or {}
    opts.loading_text = opts.loading_text or _("加载中…")
    opts.empty_text = opts.empty_text or _("书城暂无内容")
    return Library.build(ctx, state, opts)
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
    desktop._store_state = nil
    desktop:rebuild()
end

--- 异步拉取书城列表。
---@param desktop table
function Store.fetch(desktop)
    --- 写入书城状态并重建。
    ---@param books table|nil
    ---@param err string|nil
    local function done(books, err)
        if desktop._closed or desktop.tab ~= "store" then return end
        desktop._store_state = {
            books = books or {},
            err = err,
        }
        desktop:rebuild()
    end

    if desktop._store_fetch_cancel then
        desktop._store_fetch_cancel:cancel()
        desktop._store_fetch_cancel = nil
    end

    Store.syncPageSize(desktop)
    local source = desktop.source
    local generation = desktop.source_generation or 0
    local page = desktop.store_page or desktop.page or 1
    local page_size = desktop.store_page_size or desktop.page_size or 1
    local search = (desktop.filter and desktop.filter.search) or ""

    if not source or not source.configured or not source:configured() then
        done({}, _("请先在设置里配置当前数据源"))
        return
    end
    if not source.listStoreAsync then
        done({}, _("当前数据源不支持书城"))
        return
    end
    desktop._store_fetch_cancel = source:listStoreAsync({
        page = page,
        page_size = page_size,
        search = search,
    }, function(res, err)
        if desktop._closed or desktop.tab ~= "store"
            or desktop.source ~= source or (desktop.source_generation or 0) ~= generation then
            return
        end
        desktop._store_fetch_cancel = nil
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        desktop.store_total = tonumber(res.count) or 0
        local books = res.data or {}
        BookStore.rememberMany(books)
        done(books)
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
