--[[--
阅读页栏设置预览：全宽、接近真实条带高度，和桌面那排小开关不是一类东西。

@module koplugin.book.ui.reader.bars.preview
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Overlay = require("ui.desktop.settings.overlay")
local UI = require("ui.components.bookui")
local Items = require("ui.reader.bars.items")
local Layout = require("ui.reader.bars.layout")

local Preview = {}

--- 造一条带边框的预览条。
---@param width number
---@param which string "top"|"bottom"
---@return table
function Preview.build(width, which)
    local bar_h = which == "bottom" and UI.sz(56) or UI.sz(48)
    local inner = Widget:new{
        dimen = Geom:new{ w = math.max(1, width - 2), h = math.max(1, bar_h - 2) },
    }
    function inner:paintTo(bb, x, y)
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
        local ctx = Items.sampleContext()
        local pad = UI.sz(10)
        Items.paint(bb, x + pad, y, math.max(1, self.dimen.w - pad * 2), self.dimen.h, Layout.get(which), ctx, {
            face = UI.face("xx_smallinfofont", 13),
            fgcolor = Blitbuffer.COLOR_BLACK,
            bar_h = UI.sz(8),
        })
    end
    return Overlay.previewBox(width, inner, bar_h)
end

return Preview
