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
    opts.loading_text = opts.loading_text or _("加载书城…")
    opts.empty_text = opts.empty_text or _("书城暂无内容")
    return Library.build(ctx, state, opts)
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

    local function run()
        local source = desktop.source or desktop.api
        if not source or not source.configured or not source:configured() then
            done({}, _("请先在设置里配置当前数据源"))
            return
        end
        if desktop.syncStorePageSize then
            desktop:syncStorePageSize()
        elseif desktop.syncLibraryPageSize then
            desktop:syncLibraryPageSize()
        end
        local f = desktop.store_filter or desktop.filter or {}
        local res, err
        local ok, thrown = pcall(function()
            res, err = source:listStore{
                page = desktop.store_page or desktop.page or 1,
                pageSize = desktop.store_page_size or desktop.page_size or 1,
                search = f.search or "",
            }
        end)
        if not ok then
            done({}, tostring(thrown))
            return
        end
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        desktop.store_total = tonumber(res.count) or 0
        local books = res.data or {}
        Cache.rememberMany(books)
        done(books)
    end

    UIManager:scheduleIn(0, function()
        local ok, err = pcall(run)
        if not ok then
            done({}, tostring(err))
        end
    end)
end

return Store
