--[[--
统计页「本年」：指标行、月图、热力图铺满内容宽；封面墙在这块宽度里居中。
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Geom = require("ui/geometry")
local Container = require("ui/widget/container/widgetcontainer")
package.preload["ui.widgets.book"] = function()
    return {
        cover = function(_, _, _, cw, ch)
            return Container:new{ dimen = Geom:new{ w = cw, h = ch } }
        end,
    }
end

Kit.sections.insight = { hidden_pages = {}, hidden_cards = {} }
local Year = require("desktop.pages.insight.year")

local width = 500
local page = Year:build{
    desktop = { plugin = {}, source = {} },
    state = {
        calendar = { days = {} },
        finished = { { last_time = os.time(), title = "甲" } },
    },
    width = width,
    height = 800,
    open_book = function() end,
}
Assert.eq(page:getSize().w, width, "本年页内容宽等于给定宽度")

local maps = Kit.find(page, function(w) return w.cols and w.cell end)
Assert.eq(#maps, 1)
Assert.eq(maps[1]:getSize().w, width, "热力图铺满内容宽")

local charts = Kit.find(page, function(w) return w.align == "top" and w._size and w._size.w == width end)
Assert.is_true(#charts >= 1, "月图铺满内容宽")

local wall
for _idx, w in ipairs(Kit.find(page, function(w) return w.dimen and w.dimen.w == width and w[1] and w[1].align == "center" end)) do
    wall = w
end
Assert.is_true(wall ~= nil, "封面墙外框是内容宽")
local inner = wall[1]:getSize().w
Assert.is_true(inner < width, "不满一行的封面比内容窄")
Assert.eq(wall.dimen.w, width)

return true
