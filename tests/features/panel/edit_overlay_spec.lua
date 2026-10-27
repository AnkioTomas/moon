--[[-- features.panel.edit_overlay 离线用例。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
local Themed = require("support.theme_stubs")

Kit.install()
Themed.install()

local Edit = require("features.panel.edit_overlay")

local moves, disables = {}, {}
local overlay = Edit.wrap({ id = "night" }, {
    id = "night",
    width = 80,
    height = 64,
    index = 2,
    count = 3,
}, {
    on_move = function(id, delta) moves[#moves + 1] = { id = id, delta = delta } end,
    on_disable = function(id) disables[#disables + 1] = id end,
})
Assert.eq(#overlay, 3)

local tools = Kit.buttons(overlay[3])
Assert.len(tools, 3)
Assert.eq(tools[1].icon, "delete")
Assert.eq(tools[2].icon, "chevron_left")
Assert.eq(tools[3].icon, "chevron_right")
tools[1]:onTapThemeButton()
Assert.eq(disables[1], "night")
tools[2]:onTapThemeButton()
tools[3]:onTapThemeButton()
Assert.eq(moves[1].id, "night")
Assert.eq(moves[1].delta, -1)
Assert.eq(moves[2].delta, 1)

-- 编辑遮罩吞普通滑动，但对角滑动（KOReader 截图手势）放行。
local shield = overlay[2]
Assert.is_true(shield:onPanelEditShieldSwipe(nil, { direction = "west" }))
Assert.is_false(shield:onPanelEditShieldSwipe(nil, { direction = "diagonal" }))

-- 仅一项时不可停用、不可移动：按钮灰显，点按不回调
local lone_called = false
local lone = Edit.wrap({ id = "wifi" }, {
    id = "wifi", width = 80, height = 64, index = 1, count = 1,
}, {
    on_move = function() lone_called = true end,
    on_disable = function() lone_called = true end,
})
for _, b in ipairs(Kit.buttons(lone[3])) do
    Assert.is_true(b.enabled == false)
    b:onTapThemeButton()
end
Assert.is_true(lone_called == false)

local picked
Edit.showAddDialog({ { id = "wifi", title = "WiFi" } }, function(id) picked = id end)
local sheet = Themed.last("sheet")
Assert.is_true(sheet.shown)
Assert.eq(sheet.title, "添加动作")
Assert.eq(sheet.items[1].text, "WiFi")
sheet.items[1].callback()
Assert.eq(picked, "wifi")
Assert.eq(sheet.items[#sheet.items].text, "关闭")

Edit.showAddDialog({}, function() end)
sheet = Themed.last("sheet")
Assert.eq(sheet.items[1].text, "没有可添加的动作")
Assert.is_true(sheet.items[1].enabled == false)

return true
