--[[--
ui.themes.widgets.tap：嵌套点击区只认自己发出的事件，外层的点按不被子控件截走。

@module tests.ui.themes.widgets.tap_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Tap = require("ui.themes.widgets.tap")

local hits = {}
local inner = Tap.wrap({ getSize = function() return { w = 10, h = 10 } end }, function() hits[#hits + 1] = "inner" end)
local outer = Tap.wrap(inner, function() hits[#hits + 1] = "outer" end)

Assert.eq(outer.ges_events.TapThemeArea.args, outer)
-- KOReader 派发外层的 TapThemeArea 时先经过子控件：子控件不接，回到外层。
Assert.is_nil(inner:onTapThemeArea(outer, {}))
Assert.is_true(outer:onTapThemeArea(outer, {}))
Assert.is_true(inner:onTapThemeArea(inner, {}))
Assert.eq(table.concat(hits, ","), "outer,inner")

return true
