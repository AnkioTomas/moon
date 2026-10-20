--[[-- 书城：来源切换、默认不加载、搜索与分页离线用例。 @module tests.desktop.pages.store_spec --]]

local Assert = require("support.assert")

local build_opts
local search_apply
local remembered
package.preload["desktop.pages.library"] = function()
    local Library = {}
    Library.__index = Library
    function Library:new(opts)
        opts = opts or {}
        return setmetatable({
            desktop = opts.desktop or opts[1],
            page_size = 2,
        }, Library)
    end
    function Library:build(_ctx, _state, opts)
        build_opts = opts
        return { books = _state.books, opts = opts }
    end
    function Library:showSearch(apply)
        search_apply = apply
    end
    function Library.chipRowHeight() return 0 end
    function Library.gridMetrics()
        return { page_size = 2 }
    end
    return Library
end
package.preload["book.store"] = function()
    return { rememberMany = function(books) remembered = books end }
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function() end }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end
package.preload["gettext"] = function()
    return function(value) return value end
end

local saved = 0
local store_settings = { enabled = true, zlib_enabled = true, opds_enabled = false, provider = "" }
package.preload["utils.settings"] = function()
    return {
        get = function() return store_settings end,
        save = function() saved = saved + 1 end,
    }
end
local source_searches = {}
local searchable = {
    id = "wechat",
    searchAsync = function(_, keyword, cb)
        source_searches[#source_searches + 1] = keyword
        cb({ data = { { source_id = "wechat", stable_id = "w1", title = "书" } } })
        return { cancel = function() end }
    end,
}
package.preload["source.registry"] = function()
    return {
        listEnabled = function() return { { id = "local", name = "本地" }, { id = "wechat", name = "微信读书" } } end,
        resolve = function(id) return id == "wechat" and searchable or {} end,
    }
end
local picker
package.preload["ui.themes.widgets.list"] = function()
    return { new = function(_, opts) picker = opts; return { show = function() end } end }
end
package.preload["ui.themes"] = function() return { px = function(n) return n end } end

local requests = 0
local request_opts
package.preload["store.zlib"] = function()
    return {
        listStoreAsync = function(_, opts, cb)
            requests = requests + 1
            request_opts = opts
            local books = {}
            for i = 1, 205 do books[i] = { stable_id = tostring(i), source_id = "zlib" } end
            cb({ data = books, count = 999 })
            return { cancel = function() end }
        end,
    }
end

local Store = require("desktop.pages.store")
local view_updates = 0
local desktop = {
    filter = { category = "历史" },
    tab = "store",
    dimen = { w = 600, h = 800 },
    contentHeight = function() return 716 end,
    updateView = function() view_updates = view_updates + 1 end,
    ctx = function(self) return { desktop = self } end,
}
desktop.library = require("desktop.pages.library"):new{ desktop = desktop }
local store = Store:new{ desktop = desktop, name = "store" }
Assert.eq(store.name, "store")
Assert.eq(store.desktop, desktop)
desktop.store = store

-- 复用图书馆网格，工具栏只允许搜索。
store:build({ desktop = desktop }, {}, {})
Assert.is_true(build_opts.search_only)
Assert.is_false(build_opts.show_status)
Assert.is_true(type(build_opts.on_search) == "function")
Assert.is_nil(build_opts.on_clear)
Assert.eq(build_opts.empty_text, "点击搜索按钮查找书籍")
Assert.eq(build_opts.provider.text, "Z站")

-- 来源 = 启用的书城后端 + 带 searchAsync 的启用书源（local 没有就不列）。
local providers = Store.providers()
Assert.len(providers, 2)
Assert.eq(providers[1].id, "zlib")
Assert.eq(providers[2].id, "wechat")

-- 总开关关闭：没有任何来源，底栏不显示书城。
store_settings.enabled = false
Assert.len(Store.providers(), 0)
store_settings.enabled = true

-- 默认不加载：没搜索词不发请求。
store:updateView()
Assert.eq(requests, 0)
Assert.len(store.state.books, 0)

-- 搜索由本页接管：留在 store tab、回第一页并丢弃旧结果。
build_opts.on_search()
Assert.is_true(type(search_apply) == "function")
search_apply("Lua")
Assert.eq(store.search, "Lua")
Assert.eq(desktop.filter.category, "历史")
Assert.eq(store.page, 1)
Assert.is_nil(store.state)
Assert.eq(view_updates, 1)

search_apply("")
Assert.is_nil(store.search)
Assert.eq(view_updates, 2)

-- 切来源：记住选择、保留搜索词、对新来源重搜。
store.search = "Lua"
build_opts.provider.on_pick({})
picker.items[2].callback()
Assert.eq(store.provider_id, "wechat")
Assert.eq(store_settings.provider, "wechat")
Assert.eq(saved, 1)
Assert.eq(store.search, "Lua")
Assert.is_nil(store.state)
store:fetch()
Assert.eq(source_searches[1], "Lua")
Assert.eq(store.books[1].stable_id, "w1")
Assert.eq(requests, 0)
picker.items[1].callback()
store.search = nil

-- 后端固定只请求第一页最多 200 本，后续页在内存中切片；不依赖当前源。
desktop.source = { id = "wechat" }
desktop.source_generation = 1
desktop.tab = "store"
store.page = 1
store:fetch()
Assert.eq(request_opts.page, 1)
Assert.eq(request_opts.page_size, 200)
Assert.eq(requests, 1)
Assert.len(store.books, 200)
Assert.len(remembered, 200)
Assert.eq(store.total, 200)
Assert.len(store.state.books, 2)
Assert.eq(store.state.books[1].stable_id, "1")

store:gotoPage(2)
Assert.eq(requests, 1)
Assert.eq(store.page, 2)
Assert.len(store.state.books, 2)
Assert.eq(store.state.books[1].stable_id, "3")
store:onEvent("swipe", { direction = "east" })
Assert.eq(store.page, 1)
store:onEvent("swipe", { direction = "west" })
Assert.eq(store.page, 2)

store.state = nil
local page = store:updateView()
Assert.eq(requests, 1)
Assert.eq(page.books[1].stable_id, "3")

Assert.eq(store:syncPageSize(), 2)
Assert.eq(store.page_size, 2)

store:applySearch("Lua")
store:fetch()
Assert.eq(requests, 2)
Assert.eq(request_opts.search, "Lua")
store:applySearch("")
Assert.is_nil(store.search)
store:build({ desktop = desktop }, {}, {})
-- zlib 没有导航项，不出现「上级」。
Assert.is_nil(build_opts.on_back)

-- OPDS：同一页类换后端；导航项下钻压栈、书进详情、「上级」出栈，请求带栈顶 feed。
local opds_requests = {}
package.preload["store.opds"] = function()
    return {
        listStoreAsync = function(_, opts, cb)
            opds_requests[#opds_requests + 1] = opts
            cb({ data = {
                { title = "新书", feed = "http://nas/opds/new" },
                { source_id = "opds", stable_id = "b1", title = "书" },
            }, count = 2 })
            return { cancel = function() end }
        end,
    }
end
local detail_opened
package.preload["desktop.detail"] = function()
    return { open = function(_, origin, book) detail_opened = { origin, book } end }
end
store_settings.opds_enabled = true
local opds = Store:new{ desktop = desktop, name = "store" }
opds.provider_id = "opds"
desktop.tab = "store"
opds:fetch()
Assert.is_nil(opds_requests[1].feed)
Assert.len(opds.books, 2)
opds:build({ desktop = desktop }, {}, {})
Assert.is_nil(build_opts.on_back)

build_opts.on_open(opds.books[2])
Assert.eq(detail_opened[1], "store")
Assert.eq(detail_opened[2].stable_id, "b1")

opds.search = "旧搜索"
build_opts.on_open(opds.books[1])
Assert.len(opds.trail, 1)
Assert.is_nil(opds.search)
Assert.is_nil(opds.books)
opds:fetch()
Assert.eq(opds_requests[2].feed, "http://nas/opds/new")

opds:build({ desktop = desktop }, {}, {})
Assert.is_true(type(build_opts.on_back) == "function")
build_opts.on_back()
Assert.len(opds.trail, 0)
opds:fetch()
Assert.is_nil(opds_requests[3].feed)

-- 搜索回到目录根；换源复位清空 trail。
opds.trail = { { title = "x", feed = "http://nas/x" } }
opds:applySearch("lua")
Assert.len(opds.trail, 0)
opds.trail = { { title = "x", feed = "http://nas/x" } }
opds:onEvent("source_changed")
Assert.len(opds.trail, 0)
