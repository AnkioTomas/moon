--[[--
desktop.pages.library：删书后切到系列页签再切回 / 刷新，总数仍按库查询（不被当前一页顶替）。

@module tests.desktop.library_delete_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
require("support.theme_stubs").install()

local Container = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")
package.preload["ui.widgets.book"] = function()
    local function box(w, h) return Container:new{ dimen = Geom:new{ w = w, h = h } } end
    return {
        title = function(book) return book.title end,
        author = function() return "" end,
        pct = function() return 0 end,
        isRead = function() return false end,
        captionExtra = function() return 26 end,
        cover = function(_, _, _, cw, ch) return box(cw, ch), cw, ch end,
        tappable = function(w, h) return box(w, h) end,
        widget = function(_, _, _, cw, ch) local c = box(cw, ch); return c, ch, c end,
        openingBar = function() return box(1, 1) end,
    }
end

-- 60 本书的库：分页查询与系列计数都按当前库算。
local books = {}
for i = 1, 60 do books[i] = { source_id = "moon", stable_id = "b" .. i, title = "书" .. i, series = i % 3 == 0 and "S" or "" } end
local catalog = {
    libraryScope = function(id) return id end,
    listLibraryAsync = function(_, opts, cb)
        local first = (opts.page - 1) * opts.page_size
        local page = {}
        for i = first + 1, math.min(#books, first + opts.page_size) do page[#page + 1] = books[i] end
        cb({ data = page, count = #books })
        return { cancel = function() end }
    end,
    groupCountsAsync = function(_, column, cb)
        local counts, order = {}, {}
        for _idx, b in ipairs(books) do
            local v = b[column] or ""
            if not counts[v] then counts[v] = 0; order[#order + 1] = v end
            counts[v] = counts[v] + 1
        end
        local rows = {}
        for _idx, v in ipairs(order) do rows[#rows + 1] = { [column] = v, count = counts[v] } end
        cb(rows)
        return { cancel = function() end }
    end,
}
package.preload["book.catalog"] = function() return catalog end
package.preload["utils.settings"] = function()
    return { get = function() return Kit.display end, save = function() end }
end

local CoverCell = require("ui.widgets.cover")
CoverCell.denseCoverMetrics = function() return 40, 40, 60, 1, 0, 0, 86 end
local Library = require("desktop.pages.library")

local source = { id = "moon" }
local desktop = {
    plugin = {}, dimen = { w = 600 }, tab = "library", source = source,
    contentHeight = function() return 600 end,
    updateView = function() end,
}
local library = Library:new{ desktop = desktop, view = "list" }
desktop.library = library
local ctx = { width = 600, height = 600, desktop = desktop, source = source, plugin = desktop.plugin }
desktop.ctx = function() return ctx end
library.metrics = function() return { page_size = 25, rows = 5, grid_h = 400, top_h = 40, row_h = 80 } end

local function settle()
    library:updateView()
    require("support.stubs").flush()
    library:updateView()
    require("support.stubs").flush()
end

settle()
Assert.eq(library.total, 60)
Assert.len(library.state.books, 25)

-- 删一本：书架变化 → 切系列页签 → 切回书籍
table.remove(books, 5)
library:onEvent("shelf_changed")
library:selectGroup("series")
settle()
local sum = 0
for _idx, row in ipairs(library.groups.rows) do sum = sum + row.count end
Assert.eq(sum, 59)
library:selectGroup("books")
settle()
Assert.eq(library.total, 59)
Assert.eq(library:pages(), 3)
Assert.len(library.state.books, 25)

-- 刷新（shelf_changed）后同样
library:onEvent("shelf_changed")
settle()
Assert.eq(library.total, 59)
return true
