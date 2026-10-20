--[[--
设备名称与头像：用户在设置「设备」页自定义；没改过名称就叫「月读 - 设备型号」，头像缺省是插件 logo。
凡是要给人看的设备名都读这里。

@module koplugin.book.utils.device
--]]

local Settings = require("utils.settings")
local Text = require("utils.text")

local DeviceInfo = {}

---@return string
function DeviceInfo.name()
    local name = Text.trim(Settings.get("utils").device_name)
    if name ~= "" then return name end
    return "月读 - " .. require("device").model
end

--- 用户选的头像文件；没选或文件没了回退插件自带 logo（插件相对路径）。
---@return string
function DeviceInfo.logo()
    local path = Settings.get("utils").device_logo
    if path ~= "" and require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then return path end
    return "logo.png"
end

return DeviceInfo
