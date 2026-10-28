--[[--
ui.themes.widgets.row：Row.choice 单选行 —— 状态缺省取当前项文案、点按弹单选列表、选了别的值才回调。

@module tests.ui.themes.widgets.row_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Row = require("ui.themes.widgets.row")

local shown = {}
package.loaded["ui.themes.widgets.list"] = {
    new = function(_self, opts)
        shown[#shown + 1] = opts
        return { show = function() end }
    end,
}

local ITEMS = { { value = "a", text = "甲" }, { value = "b", text = "乙" } }

local picked = {}
local row = Row.choice({
    width = 600, icon = "tune", title = "范围",
    items = ITEMS, current = "b",
    on_select = function(value) picked[#picked + 1] = value end,
})
Assert.contains(Kit.texts(row), "乙", "状态缺省取当前项文案")
Assert.len(Kit.taps(row), 1)

Kit.taps(row)[1]:onTapThemeArea()
Assert.len(shown, 1)
Assert.eq(shown[1].title, "范围")
Assert.eq(shown[1].current, "b")
Assert.eq(shown[1].items, ITEMS)
Assert.is_true(shown[1].centered)

shown[1].on_select(nil)
shown[1].on_select("b")
Assert.len(picked, 0, "没选或选了同一项不回调")
shown[1].on_select("a")
Assert.eq(picked[1], "a")

-- 显式 status 优先；current 不在列表里也不报错，状态留空
local custom = Row.choice({ width = 600, title = "铺法", status = "跟随全局", items = ITEMS, current = "zzz", on_select = error })
Assert.contains(Kit.texts(custom), "跟随全局")
local blank = Row.choice({ width = 600, title = "铺法", items = ITEMS, current = "zzz", on_select = error })
Assert.is_true(blank ~= nil)
