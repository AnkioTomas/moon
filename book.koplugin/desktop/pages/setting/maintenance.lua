--[[-- 维护设置项。关于（版本、主页、加群）在设置根页「我的设备」。
@module koplugin.book.desktop.pages.setting.maintenance
--]]

local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

---@class BookSettingsMaintenance
local Maintenance = {}

--- 造「关闭桌面」设置行的构造器。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance:closeRow(desktop)
    return function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "close", title = _("关闭桌面"), callback = function() desktop:onClose() end })
    end
end

return Maintenance
