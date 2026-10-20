--[[-- 设备设置项：设备名称与头像（锁屏密码界面等处显示）。
@module koplugin.book.desktop.pages.setting.device
--]]

require("l10n").apply()

local DeviceInfo = require("utils.device")
local Image = require("utils.image")
local Input = require("ui.themes.widgets.input")
local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local Text = require("utils.text")
local _ = require("gettext")

---@class BookSettingsDevice
local Device = {}

---@param desktop table
---@param key string utils 配置键
---@param value string
local function save(desktop, key, value)
    Settings.get("utils")[key] = value
    Settings.save("utils")
    desktop:updateView()
end

---@param desktop table
---@return (fun(iw: number): table)[]
function Device:rows(desktop)
    return {
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "badge", title = _("设备名称"),
                subtitle = _("留空使用「月读 - 设备型号」"),
                status = DeviceInfo.name(), status_on = true,
                callback = function()
                    Input:new{
                        title = _("设备名称"),
                        fields = { { text = Settings.get("utils").device_name, hint = DeviceInfo.name() } },
                        ok_text = _("保存"),
                        callback = function(value) save(desktop, "device_name", Text.trim(value)) end,
                    }:show()
                end,
            })
        end,
        function(iw)
            local custom = Settings.get("utils").device_logo ~= ""
            return Row.widget({
                width = iw, kind = "nav", icon = "account_circle", title = _("设备头像"),
                subtitle = _("显示在锁屏密码界面左上角"),
                status = custom and _("自定义") or _("默认"), status_on = custom,
                callback = function()
                    local current = Settings.get("utils").device_logo
                    local dir = current:match("^(.*)/")
                    local home = require("apps/filemanager/filemanagerutil").getHomeFolder()
                    require("ui.themes.widgets.path_picker"):new{
                        path = dir and require("libs/libkoreader-lfs").attributes(dir, "mode") == "directory" and current or home,
                        select_file = true,
                        filter = function(name) return Image.suffix(name) ~= nil end,
                        on_select = function(path) save(desktop, "device_logo", path) end,
                    }:show()
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, icon = "restart_alt", title = _("恢复默认头像"),
                enabled = Settings.get("utils").device_logo ~= "",
                callback = function() save(desktop, "device_logo", "") end,
            })
        end,
    }
end

return Device
