--[[-- 书城工具栏与搜索状态离线用例。 @module tests.ui.desktop.store_spec --]]

local Assert = require("support.assert")

local build_opts
local search_apply
local remembered
package.preload["ui.desktop.library"] = function()
    return {
        build = function(_ctx, _state, opts)
            build_opts = opts
            return { books = _state.books, opts = opts }
        end,
        showSearch = function(_desktop, apply)
            search_apply = apply
        end,
        syncPageSize = function(desktop)
            desktop.page_size = 2
            return 2
        end,
    }
end
package.preload["book.store"] = function()
    return { rememberMany = function(books) remembered = books end }
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function() end }
end
package.preload["gettext"] = function()
    return function(value) return value end
end

local Store = require("ui.desktop.store")
local rebuilds = 0
local desktop = {
    filter = { category = "历史" },
    store_page = 4,
    _store_state = { books = {} },
    tab = "library",
    rebuild = function() rebuilds = rebuilds + 1 end,
    ctx = function(self) return { desktop = self } end,
}

-- 书城复用图书馆网格，但工具栏只允许搜索。
Store.build({ desktop = desktop }, {}, {})
Assert.is_true(build_opts.search_only)
Assert.is_true(type(build_opts.on_search) == "function")
Assert.is_true(type(build_opts.on_clear) == "function")

-- 搜索由书城自己接管：留在书城、回第一页并丢弃旧结果。
build_opts.on_search()
Assert.is_true(type(search_apply) == "function")
search_apply("Lua")
Assert.eq(desktop.store_search, "Lua")
Assert.eq(desktop.filter.category, "历史")
Assert.eq(desktop.store_page, 1)
Assert.is_nil(desktop._store_state)
Assert.eq(desktop.tab, "store")
Assert.eq(rebuilds, 1)

-- 输入框内也能清空搜索。
search_apply("")
Assert.is_nil(desktop.store_search)
Assert.eq(rebuilds, 2)

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
desktop.store_page = 1
Store.fetch(desktop)
Assert.eq(request_opts.page, 1)
Assert.eq(request_opts.page_size, 200)
Assert.eq(requests, 1)
Assert.len(desktop._store_books, 200)
Assert.len(remembered, 200)
Assert.eq(desktop.store_total, 200)
Assert.len(desktop._store_state.books, 2)
Assert.eq(desktop._store_state.books[1].stable_id, "1")

Store.gotoPage(desktop, 2)
Assert.eq(requests, 1)
Assert.eq(desktop.store_page, 2)
Assert.len(desktop._store_state.books, 2)
Assert.eq(desktop._store_state.books[1].stable_id, "3")

-- 切 Tab 清掉渲染态后仍复用已加载结果。
desktop._store_state = nil
local page = Store.page(desktop)
Assert.eq(requests, 1)
Assert.eq(page.books[1].stable_id, "3")

-- 搜索和清除会换查询；HTTP 层负责命中持久化缓存。
Store.applySearch(desktop, "Lua")
Store.fetch(desktop)
Assert.eq(requests, 2)
Assert.eq(request_opts.search, "Lua")
Store.build({ desktop = desktop }, {}, {})
build_opts.on_clear()
Assert.is_nil(desktop.store_search)
Store.fetch(desktop)
Assert.eq(requests, 3)
Assert.eq(request_opts.search, "")
