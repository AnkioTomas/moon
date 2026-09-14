--[[-- 书城工具栏与搜索状态离线用例。 @module tests.ui.desktop.store_spec --]]

local Assert = require("support.assert")

local build_opts
local search_apply
local remembered
package.preload["ui.desktop.library"] = function()
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
package.preload["ui.components.bookui"] = function()
    return {
        barH = function() return 48 end,
        topBarH = function() return 36 end,
    }
end
package.preload["gettext"] = function()
    return function(value) return value end
end

local Store = require("ui.desktop.store")
local view_updates = 0
local desktop = {
    lifecycle = { state = "Resume" },
    filter = { category = "历史" },
    tab = "library",
    dimen = { w = 600, h = 800 },
    contentHeight = function() return 716 end,
    updateView = function() view_updates = view_updates + 1 end,
    ctx = function(self) return { desktop = self } end,
}
local store = Store.new(desktop)
Assert.eq(store.lifecycle.state, "new")
store:onCreate()
Assert.eq(store.lifecycle.state, "Create")
desktop.store = store

-- 书城复用图书馆网格，但工具栏只允许搜索。
store:build({ desktop = desktop }, {}, {})
Assert.is_true(build_opts.search_only)
Assert.is_false(build_opts.show_status)
Assert.is_true(type(build_opts.on_search) == "function")
Assert.is_true(type(build_opts.on_clear) == "function")

-- 搜索由书城自己接管：留在书城、回第一页并丢弃旧结果。
build_opts.on_search()
Assert.is_true(type(search_apply) == "function")
search_apply("Lua")
Assert.eq(store.search, "Lua")
Assert.eq(desktop.filter.category, "历史")
Assert.eq(store.page, 1)
Assert.is_nil(store.state)
Assert.eq(desktop.tab, "store")
Assert.eq(view_updates, 1)

-- 输入框内也能清空搜索。
search_apply("")
Assert.is_nil(store.search)
Assert.eq(view_updates, 2)

-- 后端固定只请求第一页最多 200 本，后续页在内存中切片。
local requests = 0
local request_opts
desktop.source = {
    id = "store-test",
    configured = function() return true end,
    listStoreAsync = function(_, opts, cb)
        requests = requests + 1
        request_opts = opts
        local books = {}
        for i = 1, 205 do books[i] = { stable_id = tostring(i) } end
        cb({ data = books, count = 999 })
        return { cancel = function() end }
    end,
}
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

-- 切 Tab 清掉渲染态后仍复用已加载结果。
store.state = nil
local page = store:updateView()
Assert.eq(requests, 1)
Assert.eq(page.books[1].stable_id, "3")

-- syncPageSize 走 gridMetrics，不借调图书馆实例。
Assert.eq(store:syncPageSize(), 2)
Assert.eq(store.page_size, 2)

-- 搜索和清除会换查询；HTTP 层负责命中持久化缓存。
store:applySearch("Lua")
store:fetch()
Assert.eq(requests, 2)
Assert.eq(request_opts.search, "Lua")
store:build({ desktop = desktop }, {}, {})
build_opts.on_clear()
Assert.is_nil(store.search)
store:fetch()
Assert.eq(requests, 3)
Assert.eq(request_opts.search, "")
store:onEvent("source_changed")
Assert.is_nil(store.books)
Assert.eq(store.page, 1)
