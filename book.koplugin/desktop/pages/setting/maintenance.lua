--[[-- 维护设置项。关于（版本、主页、加群）在设置根页「我的设备」。
@module koplugin.book.desktop.pages.setting.maintenance
--]]

local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsMaintenance
local Maintenance = {}

--- 造「调试日志」开关；控制 DEBUG/INFO，WARN/ERROR 始终写入独立日志。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance:debugLogRow(desktop)
    return function(iw)
        local enabled = MoonSettings.get("utils").book_debug_enabled
        return Row.widget({
            width = iw,
            icon = "bug_report", title = _("调试日志"),
            toggle = enabled,
            callback = function()
                MoonSettings.get("utils").book_debug_enabled = not enabled
                MoonSettings.save("utils")
                desktop:updateView()
            end,
        })
    end
end

--- 造「关闭桌面」设置行的构造器。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance:closeRow(desktop)
    return function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "close", title = _("关闭桌面"), callback = function() desktop:onClose() end })
    end
end

return Maintenance
