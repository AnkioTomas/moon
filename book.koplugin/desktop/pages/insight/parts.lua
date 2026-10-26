--[[--
统计页各页共用的小件：指标卡一行、灰色小标题、左名右值一行。

@module koplugin.book.desktop.pages.insight.parts
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Common = require("desktop.detail.common")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")

---@class BookInsightParts
local Parts = {}

--- 指标卡排成一行。
---@param items { value: string, label: string }[]
---@param width number
---@param gap number
---@return table row
---@return number height
function Parts.cards(items, width, gap)
    local card_w = math.floor((width - gap * (#items - 1)) / #items)
    local row, row_h = HorizontalGroup:new{ align = "center" }, 0
    for i, item in ipairs(items) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local card, card_h = Common.kpiCard(card_w, item.value, item.label)
        row_h = math.max(row_h, card_h)
        table.insert(row, card)
    end
    return row, row_h
end

--- 定宽单元格（TextWidget 只有 max_width，不撑开）。
---@param widget table
---@param width number
---@param right boolean|nil 右对齐
---@return table
function Parts.cell(widget, width, right)
    local Box = right and RightContainer or LeftContainer
    return Box:new{ dimen = Geom:new{ w = width, h = widget:getSize().h }, widget }
end

---@param text string
---@param width number
---@param color number|nil
---@return table
function Parts.caption(text, width, color)
    return Text.line("caption", text, { width = width, color = color or Theme.current().color.muted })
end

--- 左名右值一行；右列定宽、左列占剩余。
---@param name string
---@param value string
---@param width number
---@param value_w number
---@return table
function Parts.pair(name, value, width, value_w)
    local t = Theme.current()
    return HorizontalGroup:new{
        align = "center",
        Parts.cell(Text.line("body", name, { width = width - value_w }), width - value_w),
        Parts.cell(Text.line("caption", value, { width = value_w, color = t.color.muted }), value_w, true),
    }
end

return Parts
