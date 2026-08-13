--[[--
书城 Tab：浏览目录（listStore）
  UI 复用 Library 网格；仅当 source.capabilities.store 时出现在底栏

@module koplugin.book.ui.store
--]]

local Library = require("ui.library")
local Cache = require("moon.cache")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Store = {}

function Store.build(ctx, state, opts)
    opts = opts or {}
    opts.loading_text = opts.loading_text or _("加载中…")
    opts.empty_text = opts.empty_text or _("书城暂无内容")
    return Library.build(ctx, state, opts)
end

function Store.syncPageSize(desktop)
    Library.syncPageSize(desktop)
    desktop.store_page_size = desktop.page_size
    return desktop.store_page_size
end

function Store.pages(desktop)
    local ps = desktop.store_page_size or desktop.page_size or 1
    local total = desktop.store_total or 0
    return math.max(1, math.ceil(total / ps))
end

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

function Store.fetch(desktop)
    local function done(books, err)
        if desktop._closed or desktop.tab ~= "store" then return end
        desktop._store_state = {
            books = books or {},
            err = err,
        }
        desktop:rebuild()
    end

    if desktop._store_fetch_cancel then
        desktop._store_fetch_cancel()
        desktop._store_fetch_cancel = nil
    end

    Store.syncPageSize(desktop)
    local source = desktop.source
    local page = desktop.store_page or desktop.page or 1
    local page_size = desktop.store_page_size or desktop.page_size or 1
    local search = (desktop.filter and desktop.filter.search) or ""

    local Async = require("moon.async")
    desktop._store_fetch_cancel = Async.run(function()
        if not source or not source.configured or not source:configured() then
            return nil, _("请先在设置里配置当前数据源")
        end
        return source:listStore{
            page = page,
            pageSize = page_size,
            search = search,
        }
    end, function(ok, res, err)
        desktop._store_fetch_cancel = nil
        if desktop._closed or desktop.tab ~= "store" then
            return
        end
        if not ok or not res then
            done({}, err or _("加载失败"))
            return
        end
        desktop.store_total = tonumber(res.count) or 0
        local books = res.data or {}
        Cache.rememberMany(books)
        done(books)
    end)
end

--- Desktop rebuild 入口
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
