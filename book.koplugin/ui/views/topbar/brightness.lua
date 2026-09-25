--[[--
顶栏前光亮度。前光状态事件立刻刷。

@module koplugin.book.ui.views.topbar.brightness
--]]

local Device = require("device")
local Base = require("ui.views.topbar.base")

---@class BookTopBarBrightness : BookTopBarItem
local Brightness = {}
Brightness.__index = Brightness
setmetatable(Brightness, Base)
Brightness.id = "brightness"

--- 前光状态变化时立即刷新亮度百分比。
---@param event string|table 父组件转发的事件名称或事件对象
function Brightness:onEvent(event)
    if event == "FrontlightStateChanged" then
        self:updateView()
    end
end

--- 读取前光亮度百分比；设置隐藏或数据不可用时返回 nil。
---@return string|nil
function Brightness:read()
    if not Base.visible("brightness") then
        return nil
    end
    if not Device:hasFrontlight() then
        return nil
    end
    -- frontlightIntensity 是设备原生级数（Kindle 0..24），百分比与快捷面板同一换算。
    return string.format("%d%%", require("ui.panel.desktop").lightPercent("brightness"))
end

--- 构建前光亮度百分比对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Brightness:createWidget()
    self.metric_widget = nil
    self.rect = nil
    self.metric_widget = Base.metric("brightness_6", self:read())
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

return Brightness
