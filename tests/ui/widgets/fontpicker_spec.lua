--[[--
fontpicker：只展示本地字体（用户/本地/系统），无在线分栏；
用户分栏每行右侧提供删除按钮，确认后删除并更新列表；预览按页懒构建。

@module tests.ui.widgets.fontpicker_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local getface_n = 0
local selected
local deleted = {}
local cur_id = "Font25.ttf"

package.preload["ui/font"] = function()
    return {
        fontmap = {},
        getFace = function(_, id)
            if id:match("%.ttf$") then getface_n = getface_n + 1 end
            return { id = id, size = 12 }
        end,
    }
end
package.loaded["ui/font"] = nil

package.preload["ui.fonts"] = function()
    return {
        currentId = function() return cur_id end,
        set = function(id) selected = id; cur_id = id; return true end,
        deleteUserFont = function(id)
            deleted[#deleted + 1] = id
            if cur_id == id then cur_id = "" end
            return true
        end,
        getFace = function(id)
            if id:match("%.ttf$") then getface_n = getface_n + 1 end
            return { id = id, size = 12 }
        end,
    }
end
package.preload["ui.fonts.catalog"] = function()
    local items = {}
    for i = 1, 2 do
        items[#items + 1] = {
            id = string.format("User%d.ttf", i),
            name = "User" .. i,
            kind = "user",
        }
    end
    items[#items + 1] = {
        id = "LegacyWeb.woff",
        name = "LegacyWeb",
        kind = "user",
        woff = true,
    }
    for i = 1, 40 do
        items[#items + 1] = {
            id = string.format("Font%02d.ttf", i),
            name = string.format("Font%02d", i),
            kind = "local",
        }
    end
    for i = 1, 3 do
        items[#items + 1] = {
            id = string.format("Sys%d.ttf", i),
            name = "Sys" .. i,
            kind = "system",
        }
    end
    return {
        listLocalAsync = function(cb)
            cb(items)
            return { cancel = function() end }
        end,
    }
end
package.loaded["ui.fonts"] = nil
package.loaded["ui.fonts.catalog"] = nil
package.loaded["ui.widgets.fontpicker"] = nil

local FontPicker = require("ui.widgets.fontpicker")
FontPicker.open{ title = "字体" }

local list = Kit.shown[#Kit.shown]
Assert.eq(list.title, "字体")
Assert.eq(Kit.closed[1] ~= nil and Kit.closed[1].text, "正在加载字体列表…", "列表到了先关加载提示")

-- 底部只有 3 个本地分栏：用户 / 本地 / 系统（不再显示在线分栏）
local function tab_ids(shown)
    local ids = {}
    for _idx, tab in ipairs(shown.tabs.tabs) do ids[#ids + 1] = tab.id end
    return table.concat(ids, ",")
end
Assert.eq(tab_ids(list), "user,local,system", "只展示本地三栏，无在线栏")

-- 当前字体在本地分栏第 25 项：自动定位到本地分栏与对应页
Assert.eq(list.tabs.active, "local")
Assert.len(list.items, 40)
Assert.eq(list.page, math.ceil(25 / list.per_page))
Assert.len(Kit.find(list, function(w) return w.text == "radio_button_checked" end), 1)
Assert.is_true(getface_n >= 1 and getface_n <= list.per_page, "只构建当前页预览, got " .. getface_n)
Assert.is_nil(list.items[1].action_icon, "本地分栏不显示删除按钮")

-- 系统分栏不显示删除按钮
getface_n = 0
list:switchTab("system")
Assert.len(list.items, 3)
Assert.is_nil(list.items[1].action_icon)
Assert.eq(getface_n, 3)

-- 用户分栏每行右侧带删除按钮；WOFF 字体在页面显示「WOFF · 兼容性差」
list:switchTab("user")
Assert.len(list.items, 3)
Assert.eq(list.items[1].action_icon, "delete", "用户字体右侧必须有删除按钮")
Assert.eq(type(list.items[1].action_callback), "function")
local preview_box = list.items[1].widget()
Assert.is_true(preview_box:getSize().w >= 400, "普通字体预览应占满剩余行宽并左对齐，不挤到最右侧")
Assert.eq(list.items[3].value.id, "LegacyWeb.woff")
Assert.eq(list.items[3].action_icon, "delete", "WOFF 用户字体同样支持一键删除")
local page_texts = table.concat(Kit.texts(list), "|")
Assert.is_true(page_texts:find("WOFF · 兼容性差", 1, true) ~= nil, "页面应明确提示 WOFF 兼容性差")

-- 选择 WOFF 字体先弹兼容性警告确认，确认后才应用
selected = nil
list.on_select(list.items[3].value)
local woff_warn = Kit.shown[#Kit.shown]
Assert.eq(woff_warn.ok_text, "仍要使用")
Assert.is_true(woff_warn.text:find("兼容性差", 1, true) ~= nil)
Assert.is_nil(selected, "确认前不得提前应用 WOFF 字体")
woff_warn.ok_callback()
Assert.eq(selected, "LegacyWeb.woff")

-- 点击删除先确认，确认后删文件并立即刷新列表
list.items[1].action_callback()
local confirm_dlg = Kit.shown[#Kit.shown]
Assert.eq(confirm_dlg.ok_text, "删除")
Assert.is_true(confirm_dlg.text:find("User1", 1, true) ~= nil)
confirm_dlg.ok_callback()
Assert.eq(deleted[1], "User1.ttf")
Assert.len(list.items, 2, "删除后列表立刻移除该项")
Assert.eq(list.items[1].value.id, "User2.ttf")
Assert.eq(Kit.shown[#Kit.shown].text, "已删除：User1")

-- 选中本地字体：关列表、写设置、提示
list:switchTab("local")
Kit.taps(list)[1]:onTapThemeArea()
Assert.eq(Kit.closed[#Kit.closed], list)
Assert.is_true(selected ~= nil and selected:match("^Font%d+%.ttf$") ~= nil)

-- 首次无选中项默认打开「用户」分栏；指定 initial_tab = "system" 切到系统栏
FontPicker.open{ title = "西文字体", initial_tab = "system", current_id = function() return "" end }
Assert.eq(Kit.shown[#Kit.shown].tabs.active, "system")
FontPicker.open{ title = "字体", current_id = function() return "" end }
Assert.eq(Kit.shown[#Kit.shown].tabs.active, "user")

return true
