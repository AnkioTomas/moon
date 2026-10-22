--[[--
统计页「榜单」页：今年最长阅读、常读作者、常读题材（都按今年读完的书）。

@module koplugin.book.desktop.pages.insight.ranks
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Calc = require("book.insight_calc")
local Catalog = require("book.catalog")
local Layout = require("desktop.pages.insight.layout")
local Parts = require("desktop.pages.insight.parts")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightRanks
local Ranks = {}

local TOP = 5

--- 构建榜单页：三个榜各占一块，拿到额外高度就多列几名（最多 TOP + 4）。
---@param ctx { state: table, width: number, height: number, open_book: fun(book: table) }
---@return table
function Ranks:build(ctx)
    local state, width, open_book = ctx.state, ctx.width, ctx.open_book
    local t = Theme.current()
    local xs = Theme.px(t.space.xs)
    local year = tonumber(os.date("%Y"))
    local done = Calc.finishedIn(
        state.finished or {},
        os.time{ year = year, month = 1, day = 1, hour = 0 },
        os.time{ year = year + 1, month = 1, day = 1, hour = 0 }
    )
    if #done == 0 then
        return Text.box("body", _("今年还没有读完的书"), width, { align = "center", color = t.color.muted })
    end
    local value_w = Theme.px(110)
    local row_h = Parts.pair("0", "0", width, value_w):getSize().h
    --- 一块：标题 + 前 n 名；没有内容不画。
    ---@param id string
    ---@param title string
    ---@param list fun(n: integer): { name: string, value: string, tap: function|nil }[]
    local function block(id, title, list)
        return { id = id, hi = row_h * 4, build = function(extra)
            local rows = list(TOP + math.floor(extra / row_h))
            if #rows == 0 then return nil end
            local col = VerticalGroup:new{ align = "left", Parts.caption(title, width), VerticalSpan:new{ width = xs } }
            for i, row in ipairs(rows) do
                local line = Parts.pair(T(_("%1. %2"), i, row.name), row.value, width, value_w)
                col[#col + 1] = row.tap and Tap.wrap(line, row.tap) or line
            end
            return col
        end }
    end
    local function topList(field)
        return function(n)
            local rows = {}
            for _idx, e in ipairs(Calc.top(done, field, n)) do
                rows[#rows + 1] = { name = e.name, value = T(_("%1本"), e.count) }
            end
            return rows
        end
    end
    return Layout.stack("ranks", {
        block("longest", T(_("%1年最长阅读"), year), function(n)
            local rows = {}
            for _idx, b in ipairs(Calc.longest(done, n)) do
                rows[#rows + 1] = {
                    name = b.title or b.stable_id,
                    value = Catalog.formatDuration(b.seconds),
                    tap = function() open_book(b) end,
                }
            end
            return rows
        end),
        block("authors", _("常读作者"), topList("authors")),
        block("category", _("常读题材"), topList("category")),
    }, width, ctx.height)
end

return Ranks
