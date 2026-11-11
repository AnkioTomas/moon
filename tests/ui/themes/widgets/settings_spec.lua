--[[--
主题设置弹窗：开关与单选改完就地刷新，不关窗。
@module tests.ui.themes.widgets.settings_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local shown = {}
package.loaded["ui.themes.widgets.list"] = {
    new = function(_self, opts)
        shown[#shown + 1] = opts
        return { show = function() end }
    end,
}

local Settings = require("ui.themes.widgets.settings")

local center = false
local layout = "stack"
local page = Settings:new{
    title = "最近阅读卡片",
    items = function()
        return {
            { title = "居中", toggle = true, checked = center, callback = function()
                center = not center
            end },
            {
                title = "布局",
                items = {
                    { value = "stack", text = "堆叠" },
                    { value = "stereo", text = "立体" },
                },
                current = layout,
                on_select = function(value) layout = value end,
            },
            { note = "说明文字" },
        }
    end,
}
page:show()
Assert.contains(Kit.texts(page), "最近阅读卡片")
Assert.contains(Kit.texts(page), "居中")
Assert.contains(Kit.texts(page), "关")
Assert.contains(Kit.texts(page), "堆叠")

local taps = Kit.taps(page)
Assert.is_true(#taps >= 2)
taps[1]:onTapThemeArea()
Assert.is_true(center)
Assert.contains(Kit.texts(page), "开", "开关就地刷新")

taps = Kit.taps(page)
taps[2]:onTapThemeArea()
Assert.len(shown, 1)
Assert.eq(shown[1].title, "布局")
Assert.eq(shown[1].current, "stack")
shown[1].on_select("stereo")
Assert.eq(layout, "stereo")
Assert.contains(Kit.texts(page), "立体")
Assert.is_nil((function()
    for _, o in ipairs(Kit.closed or {}) do
        if o == page then return true end
    end
end)(), "改完不关窗")

local form = Settings:new{
    title = "缓存章节",
    items = function()
        return { { title = "缓存范围", items = { { value = "all", text = "全本" } }, current = "all" } }
    end,
    buttons = function(self)
        return {
            { text = "取消", callback = function() self:close() end },
            { text = "开始", variant = "primary", callback = function() self:close() end },
        }
    end,
}
form:show()
Assert.contains(Kit.texts(form), "取消")
Assert.contains(Kit.texts(form), "开始")

return true
