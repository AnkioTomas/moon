--[[--
首页模块：大时钟（字号走 ui_scale）

@module koplugin.book.modules.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UI = require("bookui")
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

    local block_h = UI.sz(180)
    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, VerticalSpan:new{ width = UI.sz(28) })
    table.insert(vg, TextWidget:new{
        text = time_str,
        face = UI.face("cfont", 72),
        bold = true,
    })
    table.insert(vg, VerticalSpan:new{ width = UI.sz(10) })
    table.insert(vg, TextWidget:new{
        text = date_str,
        face = UI.face("xx_smallinfofont", 18),
        fgcolor = Blitbuffer.gray(0.4),
    })
    if batt then
        table.insert(vg, VerticalSpan:new{ width = UI.sz(6) })
        table.insert(vg, TextWidget:new{
            text = batt,
            face = UI.face("xx_smallinfofont", 14),
            fgcolor = Blitbuffer.gray(0.45),
        })
    end
    table.insert(vg, VerticalSpan:new{ width = UI.sz(20) })

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = block_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = block_h },
            vg,
        },
    }
end

return M
