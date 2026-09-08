--[[--
顶栏前光亮度。前光状态事件立刻刷。

@module koplugin.book.ui.components.topbar.brightness
--]]

local Device = require("device")
local Base = require("ui.components.topbar.base")

---@class BookTopBarBrightness : BookTopBarItem
local Brightness = setmetatable({}, Base)
Brightness.__index = Brightness
Brightness.id = "brightness"

---@param event string|table
function Brightness:onEvent(event)
    if event == "FrontlightStateChanged" then
        self:refresh()
    end
end

---@return string|nil
function Brightness:read()
    if not Base.visible("brightness") then
        return nil
    end
    if not (Device:hasFrontlight() and Device.powerd and Device.powerd.frontlightIntensity) then
        return nil
    end
    local lvl = Device.powerd:frontlightIntensity()
    if type(lvl) ~= "number" then
        return nil
    end
    return string.format("%d%%", lvl)
end

---@return table|nil
function Brightness:build()
    self.widget = nil
    self.rect = nil
    self.widget = Base.metric("brightness_6", self:read())
    return self.widget
end

return Brightness
