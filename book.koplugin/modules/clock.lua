--[[--
首页模块：大时钟（对齐 SimpleUI module_clock 的核心，去掉主题花活）

@module koplugin.book.modules.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local M = {
    id = "clock",
    title = "时钟",
}

local WEEKDAYS = {
    "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六",
}

function M.build(ctx)
    local w = ctx.width
    local now = os.date("*t", os.time())
    local time_str = string.format("%02d:%02d", now.hour, now.min)
    local date_str = string.format("%04d-%02d-%02d  %s",
        now.year, now.month, now.day, WEEKDAYS[now.wday] or "")

    local batt
    if Device:hasBattery() then
        local ok, powerd = pcall(function() return Device:getPowerDevice() end)
        if ok and powerd and powerd.getCapacity then
            local cap = powerd:getCapacity()
            if cap then
                batt = string.format("电量 %d%%", cap)
            end
        end
    end

    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(28) })
    table.insert(vg, TextWidget:new{
        text = time_str,
        face = Font:getFace("cfont", 72),
        bold = true,
    })
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(vg, TextWidget:new{
        text = date_str,
        face = Font:getFace("xx_smallinfofont", 18),
        fgcolor = Blitbuffer.gray(0.4),
    })
    if batt then
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(vg, TextWidget:new{
            text = batt,
            face = Font:getFace("xx_smallinfofont", 14),
            fgcolor = Blitbuffer.gray(0.45),
        })
    end
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(20) })

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = Screen:scaleBySize(160) },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(160) },
            vg,
        },
    }
end

return M
