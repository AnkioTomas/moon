--[[-- 短按手动旋转；有重力传感器时长按选择自动旋转策略，复用 KOReader 设置与事件。
@module koplugin.book.features.panel.actions.desktop.rotate
--]]

local _ = require("gettext")
local Device = require("device")
local has_sensor = Device:hasGSensor()

---@type BookQuickPanelAction
return {
    id = "rotate",
    title = _("旋转屏幕"),
    icon = "screen_rotation_alt",
    scope = "desktop",
    event = "IterateRotation",
    active = has_sensor and function()
        return G_reader_settings:isTrue("input_ignore_gsensor") or G_reader_settings:isTrue("input_lock_gsensor")
    end or nil,
    label = has_sensor and function()
        if G_reader_settings:isTrue("input_ignore_gsensor") then return _("旋转·关闭自动") end
        if G_reader_settings:isTrue("input_lock_gsensor") then return _("旋转·仅180°") end
        return _("旋转·自动")
    end or nil,
    hold = has_sensor and function()
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        local ignore = G_reader_settings:isTrue("input_ignore_gsensor")
        local locked = G_reader_settings:isTrue("input_lock_gsensor")
        local current = ignore and 3 or (locked and 2 or 1)
        local options = {
            { title = _("自动旋转"), ignore = false, lock = false },
            { title = _("仅允许180°自动旋转"), ignore = false, lock = true },
            { title = _("关闭自动旋转"), ignore = true },
        }
        local items = {}
        for index, option in ipairs(options) do
            items[#items + 1] = {
                text = option.title,
                variant = current == index and "primary" or "normal",
                callback = function()
                    if option.lock ~= nil and G_reader_settings:isTrue("input_lock_gsensor") ~= option.lock then
                        UIManager:broadcastEvent(Event:new("SetLockGSensor", option.lock))
                    end
                    if G_reader_settings:isTrue("input_ignore_gsensor") ~= option.ignore then
                        UIManager:broadcastEvent(Event:new("ToggleGSensor"))
                    end
                end,
            }
        end
        require("ui.themes.widgets.sheet"):new{ title = _("自动旋转"), items = items }:show()
    end or nil,
}
