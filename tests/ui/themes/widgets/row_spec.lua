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

-- 行间说明：文字起点与带图标行的标题列对齐，高度随文本撑开。
local note = Row.note(600, "说明文字")
Assert.eq(note:getSize().w, 600)
Assert.is_true(note:getSize().h > 0)

-- 右侧独立动作按钮（如删除按钮）：与整行点按各自独立触发，互不串扰。
local row_taps, action_taps = 0, 0
local with_action = Row.widget({
    width = 600, title = "用户字体",
    callback = function() row_taps = row_taps + 1 end,
    action_icon = "delete",
    action_callback = function() action_taps = action_taps + 1 end,
})
local taps = Kit.taps(with_action)
Assert.len(taps, 2, "整行与右侧动作按钮各自拥有点击区")
taps[2]:onTapThemeArea()
Assert.eq(action_taps, 1)
Assert.eq(row_taps, 0)
taps[1]:onTapThemeArea()
Assert.eq(row_taps, 1)

-- 彩色 soft 主题下，选中行的右侧动作按钮不随选中反白，保持 muted 灰度（回归：禁止把 24 位 RGB 选中色塞给 Color8 截断成白色）
Kit.use("soft")
local Device = require("device")
local orig_color_enabled = Device.screen.isColorEnabled
Device.screen.isColorEnabled = function() return true end
local Theme = require("ui.themes")
local soft_sel = Row.widget({
    width = 600, title = "已选字体",
    selected = true,
    action_icon = "delete",
    action_callback = function() end,
})
local del_icons = Kit.find(soft_sel, function(w) return w.text == "delete" end)
Assert.len(del_icons, 1)
Assert.eq(del_icons[1].fgcolor, Theme.current().color.muted, "浅底选中行删除图标保持 muted，不反白")

-- 反色 bold 主题（selected.ink == 0xFF 深底反白）下，选中行删除图标保持白色可见
Kit.use("bold")
local bold_sel = Row.widget({
    width = 600, title = "已选字体",
    selected = true,
    action_icon = "delete",
    action_callback = function() end,
})
local bold_del = Kit.find(bold_sel, function(w) return w.text == "delete" end)
Assert.len(bold_del, 1)
Assert.eq(bold_del[1].fgcolor, 0xFF, "深底反白主题选中行删除图标保持白色")
Device.screen.isColorEnabled = orig_color_enabled
