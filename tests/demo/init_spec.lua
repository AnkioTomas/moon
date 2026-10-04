--[[--
book.koplugin/demo 冒烟：主菜单项；三套主题下每个演示条目、两张展示页的每个交互都跑一遍不报错。
组件 API 变了、演示没跟上时这里先红。

@module tests.demo.init_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local fm_order = { setting = { "book_library", "network" } }
local reader_order = { setting = { "book_library", "screen" } }
package.preload["ui/elements/filemanager_menu_order"] = function() return fm_order end
package.preload["ui/elements/reader_menu_order"] = function() return reader_order end
package.loaded["ui/elements/filemanager_menu_order"] = nil
package.loaded["ui/elements/reader_menu_order"] = nil
package.loaded["demo"] = nil
local Demo = require("demo")

-- 主菜单：设置页紧跟「月读」；每次建菜单都会调，顺序表只插一次。
local menu = {}
Demo.addToMainMenu(menu)
Demo.addToMainMenu(menu)
Assert.eq(menu.book_theme_demo.sorting_hint, "setting")
Assert.eq(table.concat(fm_order.setting, ","), "book_library,book_theme_demo,network")
Assert.eq(table.concat(reader_order.setting, ","), "book_library,book_theme_demo,screen")
menu.book_theme_demo.callback()
Assert.eq(Kit.shown[#Kit.shown].title, "主题组件演示")

--- 点遍控件树里所有按钮和点击区（每次点完页面会重建，所以按序号重新取）。
local function tapAll(page)
    local n = #Kit.buttons(page) + #Kit.taps(page)
    for i = 1, #Kit.buttons(page) do
        local b = Kit.buttons(page)[i]
        if b then b:onTapThemeButton() end
    end
    for i = 1, #Kit.taps(page) do
        local tap = Kit.taps(page)[i]
        if tap then tap:onTapThemeArea() end
    end
    return n
end

for _, id in ipairs({ "paper", "bold", "soft" }) do
    Kit.use(id)
    Demo.open()
    local hub = Kit.shown[#Kit.shown]
    Assert.eq(hub.subtitle, "当前：" .. ({ paper = "纸本", bold = "高对比", soft = "柔和" })[id])
    Assert.is_true(#hub.items >= 17)
    for i, item in ipairs(hub.items) do
        local before = #Kit.shown
        hub:choose(item)
        Assert.is_true(#Kit.shown > before or #Kit.scheduled > 0, id .. " 条目无反应: " .. i)
        local shown = Kit.shown[#Kit.shown]
        -- 展示页：点遍所有交互，重绘不报错。
        if type(shown.body) == "function" then
            Assert.is_true(tapAll(shown) > 3, id .. " 展示页交互太少: " .. shown.title)
            shown:paintTo(Kit.canvas(), 0, 0)
        end
    end
    Assert.is_false(Kit.closed[#Kit.closed] == hub, "首页点项不关")
end

-- 切换主题：写 display.ui_theme 并落盘，关掉旧首页、按新主题重开。
Kit.use("paper")
Demo.open()
local hub = Kit.shown[#Kit.shown]
hub:choose(hub.items[1])
local picker = Kit.shown[#Kit.shown]
Assert.is_true(picker.centered)
picker.on_select("bold")
Assert.eq(Kit.display.ui_theme, "bold")
Assert.is_true(Kit.saved >= 1)
Assert.eq(Kit.closed[#Kit.closed], hub)
Assert.eq(Kit.shown[#Kit.shown].theme.id, "bold")

-- 进度弹窗：定时推进到第 10 步后自动关；中途收起即停止。
Kit.scheduled = {}
hub = Kit.shown[#Kit.shown]
for _, item in ipairs(hub.items) do
    if item.text:match("^进度弹窗") then hub:choose(item) end
end
local dialog = Kit.shown[#Kit.shown]
local guard = 0
while #Kit.scheduled > 0 and guard < 20 do
    guard = guard + 1
    table.remove(Kit.scheduled, 1).fn()
end
Assert.eq(dialog.bar.percent, 100)
Assert.eq(Kit.closed[#Kit.closed], dialog)

return true
