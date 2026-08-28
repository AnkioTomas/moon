--[[--
Book UI 表面组件：浅背景、无边框、圆角和轻阴影。

页面只负责布局，卡片/胶囊的视觉属性集中在这里，避免每个页面各写一套
FrameContainer 参数。

@module koplugin.book.ui.components.surface
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UI = require("ui.components.bookui")

local Surface = {}

local RoundedClip = WidgetContainer:extend{}

--- 尺寸由构造时传入的 dimen 决定，不随子件变化。
---@return table Geom
function RoundedClip:getSize()
    return self.dimen
end

--- 先画子件，再用背景色把四角圆外的像素涂掉，模拟对子件的圆角裁剪。
--- 半径会夹到短边一半；无背景色或半径为 0 时退化成直接绘制子件。
---@param bb table 目标 Blitbuffer
---@param x number 左上角横坐标
---@param y number 左上角纵坐标
function RoundedClip:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
    local w, h, r = self.dimen.w, self.dimen.h, self.radius
    local color = self.background
    if not color or r <= 0 then return end
    r = math.min(r, math.floor(math.min(w, h) / 2))
    local rr = (r - 0.5) * (r - 0.5)
    for dy = 0, r - 1 do
        for dx = 0, r - 1 do
            if (dx + 0.5 - r + 0.5) ^ 2 + (dy + 0.5 - r + 0.5) ^ 2 > rr then
                bb:setPixel(x + dx, y + dy, color)
                bb:setPixel(x + w - 1 - dx, y + dy, color)
                bb:setPixel(x + dx, y + h - 1 - dy, color)
                bb:setPixel(x + w - 1 - dx, y + h - 1 - dy, color)
            end
        end
    end
end

--- 上下内边距之和，单边未指定时回落到通用 padding。
---@param opts table 表面参数
---@return number
local function verticalPadding(opts)
    return (opts.padding_top or opts.padding or 0) + (opts.padding_bottom or opts.padding or 0)
end

--- 左右内边距之和，单边未指定时回落到通用 padding。
---@param opts table 表面参数
---@return number
local function horizontalPadding(opts)
    return (opts.padding_left or opts.padding or 0) + (opts.padding_right or opts.padding or 0)
end

--- 造统一视觉的无边框圆角容器：给定宽高时先居中撑开子件（扣掉内边距），
--- opts.clip 为真再包一层 RoundedClip，防止子件（如封面图）方角盖平圆角。
---@param child table 子件
---@param opts table|nil background/width/height/dimen/radius/padding*/clip* 等参数
---@return table
local function frame(child, opts)
    opts = opts or {}
    local background = opts.background
    if type(background) == "nil" then background = UI.surface() end
    local target_w = opts.width or (opts.dimen and opts.dimen.w)
    local target_h = opts.height or (opts.dimen and opts.dimen.h)
    if target_w or target_h then
        local child_size = child:getSize()
        child = CenterContainer:new{
            dimen = Geom:new{
                w = target_w and math.max(1, target_w - horizontalPadding(opts)) or child_size.w,
                h = target_h and math.max(1, target_h - verticalPadding(opts)) or child_size.h,
            },
            child,
        }
    end
    if opts.clip then
        local size = child:getSize()
        child = RoundedClip:new{
            dimen = Geom:new{ w = size.w, h = size.h },
            radius = opts.clip_radius or opts.radius or UI.cardRadius(),
            background = opts.clip_background or background,
            child,
        }
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = opts.padding or 0,
        padding_top = opts.padding_top,
        padding_right = opts.padding_right,
        padding_bottom = opts.padding_bottom,
        padding_left = opts.padding_left,
        margin = 0,
        radius = opts.radius ~= nil and opts.radius or UI.cardRadius(),
        background = background,
        width = opts.width,
        height = opts.height,
        dimen = opts.dimen,
        child,
    }
end

--- 浅背景卡片；默认带轻阴影。
---@param child table
---@param opts table|nil
---@return table
function Surface.card(child, opts)
    opts = opts or {}
    local card = frame(child, opts)
    if opts.shadow == false then
        return card
    end

    local size = card:getSize()
    local offset = opts.shadow_offset or UI.sz(2)
    local shadow = frame(Widget:new{ dimen = Geom:new{ w = size.w, h = size.h } }, {
        width = size.w,
        height = size.h,
        radius = opts.radius or UI.cardRadius(),
        background = opts.shadow_color or Blitbuffer.COLOR_GRAY_D,
    })
    shadow.overlap_offset = { offset, offset }
    return OverlapGroup:new{
        -- 阴影只影响绘制，绝不能挤占网格、按钮等调用方的布局空间。
        dimen = Geom:new{ w = size.w, h = size.h },
        shadow,
        card,
    }
end

--- 胶囊按钮；圆角固定为实际高度的一半。
---@param child table
---@param opts table|nil
---@return table
function Surface.pill(child, opts)
    opts = opts or {}
    local size = child:getSize()
    local height = opts.height or (opts.dimen and opts.dimen.h)
        or size.h + verticalPadding(opts)
    local pill_opts = {}
    for key, value in pairs(opts) do
        pill_opts[key] = value
    end
    pill_opts.radius = UI.pillRadius(height)
    pill_opts.shadow = opts.shadow == true
    return Surface.card(child, pill_opts)
end

return Surface
