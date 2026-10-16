--[[--
书架组件：按图书馆当前排序只取放得下的几本（行×列）；一行 / 多行 / 自动按高度；
点封面开书，「更多 ›」进图书馆；空库给提示。
@module tests.desktop.home.shelf_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Container = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")

local built = 0
package.preload["ui.widgets.cover"] = function()
    return {
        gridCoverMaxH = function() return 90 end,
        denseCoverMetrics = function() return 100, 60, 90, 4, 10, 10, 110 end,
        opener = function(_, _, open) return function(book) open(nil, book) end end,
        build = function(_, book, w, _, _, on_open)
            built = built + 1
            local cell = Container:new{ dimen = Geom:new{ w = w, h = 110 } }
            cell.book, cell.on_open = book, on_open
            return cell, 110
        end,
    }
end
package.preload["ui.widgets.book"] = function() return { captionExtra = function() return 20 end } end
local asked, total = nil, 9
package.preload["book.catalog"] = function()
    return {
        libraryScope = function(id) return id end,
        listBooks = function(scope, opts)
            Assert.eq(scope, "local")
            asked = opts
            local rows = {}
            for i = 1, math.min(opts.limit, total) do rows[i] = { stable_id = "b" .. i } end
            return rows, total
        end,
        toList = function(rows, count) return { data = rows, count = count } end,
    }
end
local opened
package.loaded["desktop.open"] = { book = function(_, book) opened = book end }

local Shelf = require("desktop.pages.home.shelf")
local home = Kit.sections.home or {}
Kit.sections.home = home
local desktop = { library = { sort = "title", reset = function() end } }
function desktop:switchTab(tab) self.switched = tab end
local ctx = { plugin = {}, source = { id = "local" }, desktop = desktop }

-- 一行：只取 1×4 本，跟随图书馆排序。
home.home_shelf_rows, home.home_shelf_cols = 1, 4
local one = Shelf:heightRange(ctx, { width = 600 }).height
built = 0
local slot = Shelf:new():build(ctx, { width = 600, height = 400 })
Assert.eq(asked.limit, 4)
Assert.eq(asked.sort, "title")
Assert.eq(built, 4)

-- 两行：高度多一行；分配高度只够一行时也只取一行。
home.home_shelf_rows = 2
Assert.eq(Shelf:heightRange(ctx, { width = 600 }).height, one + 120)
Shelf:new():build(ctx, { width = 600, height = one })
Assert.eq(asked.limit, 4, "放不下第二行就不取")

-- 自动：按分配高度放满（填满模式），总数不够时只画有的。
home.home_shelf_rows = 0
built = 0
Shelf:new():build(ctx, { width = 600, height = one + 120 * 3 })
Assert.eq(asked.limit, 16)
Assert.eq(built, 9)

-- 非法行数回落一行；列数夹到 3–8。
home.home_shelf_rows, home.home_shelf_cols = 9, 20
Assert.eq(Shelf.rows(), 1)
Assert.eq(Shelf.cols(), 8)
home.home_shelf_cols = 4

-- 点封面开书；「更多 ›」进图书馆。
home.home_shelf_rows = 1
slot = Shelf:new():build(ctx, { width = 600, height = 400 })
local cell
local function find(w)
    if cell then return end
    if type(w) ~= "table" then return end
    if w.book then cell = w return end
    for _i, c in ipairs(w) do find(c) end
end
find(slot)
cell.on_open(cell.book)
Assert.eq(opened.stable_id, "b1")
Assert.contains(Kit.texts(slot), "更多 ›")
Kit.taps(slot)[1]:onTapThemeArea(nil, Kit.tap(1, 1))
Assert.eq(desktop.switched, "library")

-- 空库：提示，不画封面。
total = 0
slot = Shelf:new():build(ctx, { width = 600, height = 400 })
Assert.contains(Kit.texts(slot), "没有书籍")
