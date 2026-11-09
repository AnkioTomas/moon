--[[--
桌面手势区。壳在 init 里登记，KOReader 仍按 Desktop 的方法名派发。

@module koplugin.book.desktop.gesture
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen = Device.screen

local M = {}

--- 构造全宽手势区；y / h 是取当前屏幕坐标的函数。
---@param ges string KOReader 手势名，如 tap / swipe
---@param y fun():number 手势区顶部 y
---@param h fun():number 手势区高度
---@return table
function M.range(ges, y, h)
    return {
        GestureRange:new{
            ges = ges,
            range = function()
                return Geom:new{ x = 0, y = y(), w = Screen:getWidth(), h = h() }
            end,
        },
    }
end

--- 交给 FileManager 上 gestures 插件已配置动作的 touch zone（multiswipe 是总入口，按方向再查动作）。
--- 经 InputContainer.onGesture 调用，「禁用触摸」时它被换成过滤版，常驻手势白名单照常生效。
---@param desktop BookDesktop 当前桌面实例
---@param ev table KOReader 手势数据
---@return boolean|nil handled
function M.fm(desktop, ev)
    local fm = desktop.plugin and desktop.plugin.ui
    if not fm or not fm.gestures then return false end
    local gestures = fm.gestures
    local zones = {}
    for _idx, zone in ipairs(fm._ordered_touch_zones) do
        local id = zone.def.id
        if id == "multiswipe" or gestures.gestures[id] ~= nil then
            zones[#zones + 1] = zone
        end
    end
    local proxy = setmetatable({ _ordered_touch_zones = zones, ges_events = {} }, { __index = InputContainer })
    return InputContainer.onGesture(proxy, ev)
end

--- Dispatcher:execute 用 sendEvent，只打栈顶。桌面盖住 FM 时，FullRefresh / 前光 / Wi-Fi
--- 等真正的处理者在 FM 的 DeviceListener 等模块上。把这个代理挂到 Desktop.active_widgets：
--- 栈顶没消费的非输入事件转给 FM；输入事件不转（否则未消费手势会漏进文件管理器）。
--- broadcastEvent 不走 active_widgets，面板广播不会双触发。
---@param fm table FileManager
---@return table
function M.dispatcher(fm)
    return {
        handleEvent = function(_proxy, event)
            local handler = type(event) == "table" and event.handler
            if not handler or handler == "onGesture" or handler == "onKeyPress"
                or handler == "onKeyRepeat" or handler == "onKeyRelease"
                or handler == "onBookWindowPage" or handler == "onBookWindowClose" then
                return false
            end
            return fm:handleEvent(event)
        end,
    }
end

return M
