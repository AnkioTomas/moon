--[[-- 桌面设置入口。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["ui.themes.widgets.list"] = function()
    return { new = function(_, opts) return setmetatable(opts, { __index = { show = function() end } }) end }
end
local book_settings = { drawer_opens_desktop = true }
local ui_settings = {}
local saved_owner
local has_keys = false
package.preload["device"] = function() return { hasKeys = function() return has_keys end } end
local open_on_start
package.preload["utils.settings"] = function()
    return {
        get = function(owner) return owner == "ui" and ui_settings or book_settings end,
        save = function(owner) saved_owner = owner end,
    }
end
package.preload["menu"] = function()
    return { setOpenOnStart = function(on) open_on_start = on end }
end

local desktop = { updateView = function() end }
local Settings = require("desktop.pages.setting.desktop")
local rows = Settings:rows(desktop, false)
Assert.len(rows, 2)
Assert.eq(rows[1](600).title, "启动打开桌面")
Assert.is_false(rows[1](600).toggle)

rows[1](600).callback()
Assert.is_true(open_on_start, "关着时点开 = 设为启动项")
Settings:rows(desktop, true)[1](600).callback()
Assert.is_false(open_on_start, "开着时点关 = 取消启动项")

local drawer = rows[2](600)
Assert.eq(drawer.title, "抽屉图标打开桌面")
Assert.is_true(drawer.toggle)
drawer.callback()
Assert.eq(book_settings.drawer_opens_desktop, false)
Assert.is_false(rows[2](600).toggle)

-- 有键设备才显示「桌面物理翻页键」；缺省开，点一下关。
has_keys = true
rows = Settings:rows(desktop, false)
Assert.len(rows, 4)
local keys = rows[3](600)
Assert.eq(keys.title, "桌面物理翻页键")
Assert.is_true(keys.toggle, "缺省开")
keys.callback()
Assert.eq(book_settings.page_keys, false)
Assert.is_false(rows[3](600).toggle)

-- 「反转翻页键」读 KOReader 的 input_invert_page_turn_keys
local saved_g = _G.G_reader_settings
_G.G_reader_settings = { isTrue = function(_, k) return k == "input_invert_page_turn_keys" end }
local inv = rows[4](600)
Assert.eq(inv.title, "反转翻页键")
Assert.is_true(inv.toggle)
_G.G_reader_settings = saved_g

local inputs = Settings:inputRows(desktop)
Assert.len(inputs, 5)
for i, key in ipairs({ "pager_keys", "pager_swipe", "pager_cycle", "modal_keys" }) do
    local row = inputs[i](600)
    Assert.eq(row.toggle, key ~= "pager_cycle", "默认不开循环，保留原始边界行为")
    row.callback()
    Assert.eq(saved_owner, "ui", "只移动入口，不迁移已有配置")
    Assert.eq(ui_settings[key], key == "pager_cycle")
    inputs[i](600).callback()
    Assert.eq(ui_settings[key], key ~= "pager_cycle", "开关可独立恢复")
end
local swipe = inputs[5](600)
Assert.eq(swipe.title, "弹窗关闭手势")
Assert.eq(swipe.status, "下滑", "缺省跟 ui.swipe_dismiss=down")
ui_settings.swipe_dismiss = "off"
Assert.eq(inputs[5](600).status, "关闭")

return true
