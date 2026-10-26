--[[--
阅读页栏设置预览：全宽、接近真实条带高度，和桌面那排小开关不是一类东西。

@module koplugin.book.features.bars.preview
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Overlay = require("desktop.pages.setting.overlay")
local Theme = require("ui.themes")
local Items = require("features.bars.items")
local Layout = require("features.bars.layout")

local Preview = {}

--- KOReader 状态栏设置：开着书用 ReaderFooter 的（改完能立即重排），否则读全局设置；都没有返回 nil。
---@return table|nil settings
---@return table|nil footer ReaderFooter
function Preview.footerSettings()
    local ui = require("apps/reader/readerui").instance
    local footer = ui and ui.document and ui.view and ui.view.footer
    if footer and footer.settings then return footer.settings, footer end
    return (G_reader_settings and G_reader_settings:readSetting("footer") or nil) --[[@as table|nil]], nil
end

--- 预览用字面：与阅读页同字体、同字号（设置页预览条是全宽，按真实字号画才有参考价值）。
---@param which string
---@param fs table|nil 状态栏设置
---@return table face
---@return number size 未缩放字号
function Preview.face(which, fs)
    local size = Layout.fontSize(which, fs)
    return require("ui/font"):getFace("ffont", size), size
end

--- 预览条高度：底栏固定 56 起；顶栏按主题行高起，再加上「高度」相对缺省 12 的增减。
--- 都至少容得下当前字号的一行字。
---@param which string
---@param size number 未缩放字号
---@return number
function Preview.barHeight(which, size)
    local t = Theme.current()
    local Screen = require("device").screen
    local text_h = Screen:scaleBySize(size) + Theme.px(8)
    local base
    if which == "bottom" then
        base = Theme.px(56)
    else
        base = Theme.px(t.row.height) + Screen:scaleBySize(Layout.topHeight() - Layout.TOP_HEIGHT_DEFAULT)
    end
    return math.max(base, text_h)
end

--- 造一条带边框的预览条。每次桌面重绘都会重建，读的是当前设置，改完字号 / 高度立即生效。
---@param width number
---@param which string "top"|"bottom"
---@return table
function Preview.build(width, which)
    local t = Theme.current()
    local face, size = Preview.face(which, (Preview.footerSettings()))
    local bar_h = Preview.barHeight(which, size)
    local inner = Widget:new{
        dimen = Geom:new{ w = math.max(1, width - 2), h = math.max(1, bar_h - 2) },
    }
    function inner:paintTo(bb, x, y)
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.Color8(t.color.page))
        if Layout.divider(which) then
            bb:paintRect(x, which == "top" and y + self.dimen.h - 1 or y, self.dimen.w, 1,
                Blitbuffer.Color8(t.color.ink))
        end
        local ctx = Items.sampleContext()
        local pad = require("device").screen:scaleBySize(Layout.BAR_HORIZONTAL_PADDING)
        Items.paint(bb, x + pad, y, math.max(1, self.dimen.w - pad * 2), self.dimen.h, Layout.get(which), ctx, {
            face = face,
            fgcolor = Blitbuffer.Color8(t.color.ink),
            bar_h = Theme.px(t.progress.height),
            icons = Layout.icons(),
        })
    end
    return Overlay.previewBox(width, inner, bar_h)
end

return Preview
