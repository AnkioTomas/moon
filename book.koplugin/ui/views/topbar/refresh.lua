--[[--
顶栏刷新状态：有状态时出现在最左侧；idle 不进布局、不占位。

接 refresh_status（idle/running/ok/error）；running 时图标每 90° 滚动。
显隐变化才整条顶栏重排一次；滚动帧只 dirty 自己。
点按发 refresh_request。ok/error 约 2 秒回 idle。

@module koplugin.book.ui.views.topbar.refresh
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Icon = require("ui.components.icon")
local UIManager = require("ui/uimanager")
local Base = require("ui.views.topbar.base")

---@class BookTopBarRefresh : BookTopBarItem
---@field id string 固定为 "refresh"
---@field align string 固定为 "left"
---@field always boolean 顶栏必建，不受设置开关影响
---@field status string|nil idle|running|ok|error；缺省按 idle
---@field status_icon string|nil 覆盖默认图标的 Material 名
---@field _box table|nil 图标方盒（显隐复用，带 _spin_angle）
local Refresh = {}
Refresh.__index = Refresh
setmetatable(Refresh, Base)
Refresh.id = "refresh"
Refresh.align = "left"
Refresh.always = true

local ICONS = {
    running = "autorenew",
    ok = "check",
    error = "error",
}

local RESET_SEC = 2
local SPIN_SEC = 0.2

--- 取出方盒内的 TextWidget（真实 CenterContainer 或测试桩）。
---@param box table|nil 图标方盒
---@return table|nil 可 setText 的文字控件
local function textWidget(box)
    if not box then return nil end
    if box.setText then return box end
    local child = box[1]
    if child and child.setText then return child end
    return nil
end

--- 给方盒挂旋转绘制：running 时按 _spin_angle 滚 90° 步进。
---@param box table Icon.widget 返回的方盒
---@return table 同一方盒（已挂 paintTo）
local function enableSpinPaint(box)
    if box._spin_paint then return box end
    box._spin_paint = true
    box._spin_angle = 0
    local inner = box.paintTo
    if type(inner) ~= "function" then
        return box
    end
    ---@param bb table BlitBuffer
    ---@param x number
    ---@param y number
    function box:paintTo(bb, x, y)
        local angle = self._spin_angle or 0
        if angle == 0 then
            return inner(self, bb, x, y)
        end
        local w, h = self.dimen.w, self.dimen.h
        local tmp = Blitbuffer.new(w, h, bb:getType())
        tmp:fill(Blitbuffer.COLOR_WHITE)
        inner(self, tmp, 0, 0)
        local rot = tmp:rotatedCopy(angle)
        local rw, rh = rot:getWidth(), rot:getHeight()
        bb:blitFrom(rot,
            x + math.floor((w - rw) / 2),
            y + math.floor((h - rh) / 2),
            0, 0, rw, rh)
        tmp:free()
        rot:free()
    end
    return box
end

--- 是否应出现在顶栏布局中（非 idle）。
---@param self BookTopBarRefresh
---@return boolean
function Refresh:isShown()
    local state = self.status or "idle"
    return state == "running" or state == "ok" or state == "error"
end

--- 当前图标名。
---@param self BookTopBarRefresh
---@return string Material 图标名
function Refresh:iconName()
    if self.status_icon and self.status_icon ~= "" then
        return self.status_icon
    end
    local state = self.status or "idle"
    return ICONS[state] or "autorenew"
end

--- 确保图标方盒存在并写成当前字形。
---@param self BookTopBarRefresh
---@return table|nil 图标方盒
function Refresh:ensureBox()
    if not self._box then
        local box = Icon.widget{
            name = self:iconName(),
            size = Base.ICON_SIZE,
        }
        if not box then
            return nil
        end
        self._box = enableSpinPaint(box)
    else
        local tw = textWidget(self._box)
        if tw and tw.setText then
            tw:setText(self:iconName())
        end
    end
    return self._box
end

--- 原地改字形，只 dirty 自己。
---@param self BookTopBarRefresh
---@param name string Material 图标名
---@return nil
function Refresh:setIcon(name)
    local tw = textWidget(self._box or self.metric_widget)
    if tw and tw.setText then
        tw:setText(name)
    end
    self:dirty()
end

--- 滚动角度归零（不停定时器）。
---@param self BookTopBarRefresh
---@return nil
function Refresh:clearAngle()
    local box = self._box or self.metric_widget
    if box then
        box._spin_angle = 0
    end
end

--- 停滚动定时器并归零角度。
---@param self BookTopBarRefresh
---@return nil
function Refresh:stopSpin()
    self:unschedule()
    self:clearAngle()
end

--- running 时安排下一帧 90° 滚动；只脏本矩形。
---@param self BookTopBarRefresh
---@return nil
function Refresh:startSpin()
    self:unschedule()
    if not self.lifecycle:uiReady() or self.status ~= "running" then
        return
    end
    self._tick = function()
        if not self.lifecycle:uiReady() or self.status ~= "running" then
            return
        end
        local box = self._box or self.metric_widget
        if box then
            box._spin_angle = ((box._spin_angle or 0) + 90) % 360
            self:dirty()
        end
        self:startSpin()
    end
    UIManager:scheduleIn(SPIN_SEC, self._tick)
end

--- 应用状态；忽略 text（避免改宽重排）。ok/error 定时回 idle。
---@param self BookTopBarRefresh
---@param payload string|table|nil 状态字符串，或 { state=, icon= }
---@return nil
function Refresh:applyStatus(payload)
    self:stopSpin()
    if payload == nil or payload == "idle" then
        self.status, self.status_icon = "idle", nil
        return
    end
    if type(payload) == "string" then
        self.status = ICONS[payload] and payload or "idle"
        self.status_icon = nil
    elseif type(payload) == "table" then
        local state = payload.state or "idle"
        self.status = ICONS[state] and state or "idle"
        self.status_icon = payload.icon
    else
        self.status, self.status_icon = "idle", nil
        return
    end
    if self.status == "running" then
        return
    end
    if self.status ~= "ok" and self.status ~= "error" then
        return
    end
    if not self.lifecycle:uiReady() then return end
    self._tick = function()
        self._tick = nil
        if not self.lifecycle:uiReady() then return end
        self.status, self.status_icon = "idle", nil
        self:updateView()
    end
    UIManager:scheduleIn(RESET_SEC, self._tick)
end

--- 与 Base 契约对齐；未显示时返回 nil。
---@param self BookTopBarRefresh
---@return string|nil text
---@return string|nil icon
function Refresh:read()
    if not self:isShown() then
        return nil
    end
    local icon = self:iconName()
    return icon, icon
end

--- idle 返回零尺寸占位（不进左栏）；有状态时返回图标方盒。
---@param self BookTopBarRefresh
---@return table View 内容树根
function Refresh:createWidget()
    self.rect = nil
    if not self:isShown() then
        self.metric_widget = nil
        local dimen = Geom:new{ w = 0, h = 0 }
        return {
            dimen = dimen,
            getSize = function(self) return self.dimen end,
        }
    end
    self.metric_widget = self:ensureBox()
    return self.metric_widget
end

--- 显隐变化整条重排一次；可见期间滚动/换图标只脏自己。
---@param self BookTopBarRefresh
---@return nil
function Refresh:updateView()
    if not self.lifecycle:uiReady() then return end
    local show = self:isShown()
    local laid_out = self.metric_widget ~= nil
    if show ~= laid_out then
        if show then
            self.metric_widget = self:ensureBox()
        else
            self:stopSpin()
            self.metric_widget = nil
            self.rect = nil
        end
        local topbar = self.topbar
        if topbar then topbar:updateView() end
        if show and self.status == "running" then
            self:startSpin()
        end
        return
    end
    if not show then
        return
    end
    if self.status == "running" then
        self:setIcon(self:iconName())
        self:startSpin()
        return
    end
    self:clearAngle()
    self:setIcon(self:iconName())
end

--- 接受 refresh_status，更新显示。
---@param self BookTopBarRefresh
---@param event string|table 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
---@return nil
function Refresh:onEvent(event, payload)
    if event == "refresh_status" then
        self:applyStatus(payload)
        self:updateView()
    end
end

--- Resume：按当前显隐同步；running 则继续滚动。
---@param self BookTopBarRefresh
---@return nil
function Refresh:onResume()
    self:updateView()
end

--- Pause：停滚动定时器。
---@param self BookTopBarRefresh
---@return nil
function Refresh:onPause()
    self:stopSpin()
end

return Refresh
