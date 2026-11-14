--[[-- 维护设置项。关于（版本、主页、加群）在设置根页「我的设备」。
@module koplugin.book.desktop.pages.setting.maintenance
--]]

local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsMaintenance
local Maintenance = {}

---@param desktop table
---@return fun(iw: number): table
function Maintenance:refreshDiagRow(desktop)
    return function(iw)
        local settings = Settings.get("reader")
        return Row.widget({
            width = iw, kind = "toggle", icon = "bug_report",
            title = _("刷新诊断"), subtitle = _("记录触发位置和波形，重开书生效"),
            toggle = settings.refresh_diagnostics == true,
            callback = function()
                settings.refresh_diagnostics = not settings.refresh_diagnostics
                Settings.save("reader")
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
