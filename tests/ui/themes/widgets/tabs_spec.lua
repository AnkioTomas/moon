--[[-- ui.themes.widgets.tabs：订阅同款横向下划线页签，构造后可点击。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Tabs = require("ui.themes.widgets.tabs")
local HorizontalGroup = require("ui/widget/horizontalgroup")

local picked
local trailing_hits = 0
local trailing = Tabs.action({
    icon = "search", text = "搜索", accent = false,
    on_tap = function() trailing_hits = trailing_hits + 1 end,
})
local bar = Tabs.row({
    width = 400,
    tabs = {
        { id = "browse", text = "浏览" },
        { id = "installed", text = "已安装" },
        { id = "updates", text = "更新" },
    },
    active = "browse",
    on_tab = function(id) picked = id end,
    trailing = HorizontalGroup:new{ align = "center", trailing },
})
Assert.is_true(bar:getSize().h > 0)
Assert.is_true(bar:getSize().w > 0)
local labels = Kit.texts(bar)
Assert.is_true(table.concat(labels, ","):find("浏览", 1, true) ~= nil)
Assert.is_true(table.concat(labels, ","):find("已安装", 1, true) ~= nil)
Assert.is_true(table.concat(labels, ","):find("更新", 1, true) ~= nil)
Assert.is_true(table.concat(labels, ","):find("搜索", 1, true) ~= nil)

local taps = Kit.taps(bar)
Assert.is_true(#taps >= 4, "三个页签加搜索都应可点")
Assert.is_true(taps[1]:onTapThemeArea())
Assert.is_nil(picked, "当前页签不重复回调")
taps[2]:onTapThemeArea()
Assert.eq(picked, "installed")
taps[3]:onTapThemeArea()
Assert.eq(picked, "updates")
taps[#taps]:onTapThemeArea()
Assert.eq(trailing_hits, 1)

return true
