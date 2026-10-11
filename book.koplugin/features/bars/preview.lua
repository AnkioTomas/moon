--[[--
阅读页栏设置预览：全宽、接近真实条带高度，和桌面那排小开关不是一类东西。

@module koplugin.book.features.bars.preview
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Overlay = require("desktop.pages.setting.overlay")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Items = require("features.bars.items")
local Layout = require("features.bars.layout")

local Preview = {}

--- 造一条带边框的预览条。
---@param width number
---@param which string "top"|"bottom"
---@return table
function Preview.build(width, which)
    local t = Theme.current()
    local bar_h = which == "bottom" and Theme.px(56) or Theme.px(t.row.height)
    local inner = Widget:new{
        dimen = Geom:new{ w = math.max(1, width - 2), h = math.max(1, bar_h - 2) },
    }
    function inner:paintTo(bb, x, y)
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.Color8(t.color.page))
        local ctx = Items.sampleContext()
        local pad = Theme.px(10)
        Items.paint(bb, x + pad, y, math.max(1, self.dimen.w - pad * 2), self.dimen.h, Layout.get(which), ctx, {
            face = Text.face("caption"),
            fgcolor = Blitbuffer.Color8(t.color.ink),
            bar_h = Theme.px(t.progress.height),
        })
    end
    return Overlay.previewBox(width, inner, bar_h)
end

return Preview
