--[[--
统一「Page X of Y」翻页条。桌面各页禁止 ScrollableContainer，溢出用本组件。

@module koplugin.book.ui.components.pager
--]]

local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template

local Pager = {}

--- 底部分页带高度（含贴底 padding）
function Pager.bandH()
    return UI.iconSz() + UI.sz(32)
end

--- 与官方 Menu 底栏一致：首/上/页码/下/末
function Pager.widget(page, pages, handlers)
    handlers = handlers or {}
    page = tonumber(page) or 1
    pages = math.max(1, tonumber(pages) or 1)
    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    local chevron_first = "chevron.first"
    local chevron_last = "chevron.last"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
        chevron_first, chevron_last = chevron_last, chevron_first
    end
    local icon_sz = UI.iconSz()
    local spacer = HorizontalSpan:new{ width = UI.sz(32) }
    local function chev(icon, cb)
        return Button:new{
            icon = icon,
            icon_width = icon_sz,
            icon_height = icon_sz,
            bordersize = 0,
            padding = UI.sz(2),
            callback = cb,
        }
    end
    local first = chev(chevron_first, function()
        if handlers.on_first then handlers.on_first() end
    end)
    local left = chev(chevron_left, function()
        if handlers.on_prev then handlers.on_prev() end
    end)
    local right = chev(chevron_right, function()
        if handlers.on_next then handlers.on_next() end
    end)
    local last = chev(chevron_last, function()
        if handlers.on_last then handlers.on_last() end
    end)
    local info = Button:new{
        text = handlers.info_text or T(_("Page %1 of %2"), page, pages),
        text_font_face = "xx_smallinfofont",
        text_font_size = UI.fontSize(16),
        text_font_bold = false,
        bordersize = 0,
        padding = UI.sz(2),
    }
    if info.disableWithoutDimming then
        info:disableWithoutDimming()
    end
    first:enableDisable(page > 1)
    left:enableDisable(page > 1)
    right:enableDisable(page < pages)
    last:enableDisable(page < pages)
    return HorizontalGroup:new{
        first,
        spacer,
        left,
        spacer,
        info,
        spacer,
        right,
        spacer,
        last,
    }
end

--- 固定高度的分页带：控件贴底，与桌面底栏留出空隙
function Pager.band(width, page, pages, handlers)
    local bottom_pad = UI.sz(14)
    local band_h = Pager.bandH()
    return BottomContainer:new{
        dimen = Geom:new{ w = width, h = band_h },
        VerticalGroup:new{
            align = "center",
            Pager.widget(page, pages, handlers),
            VerticalSpan:new{ width = bottom_pad },
        },
    }
end

--- 把已测量的 widget 列表按 avail_h 切成多页（每页一个 VerticalGroup 的 kids 表）
function Pager.pack(widgets, avail_h)
    avail_h = math.max(1, tonumber(avail_h) or 1)
    local pages = {}
    local cur = { align = "left" }
    local used = 0
    for _, w in ipairs(widgets or {}) do
        if w then
            local wh = w.getSize and w:getSize().h or 0
            if #cur > 1 and used + wh > avail_h then
                table.insert(pages, cur)
                cur = { align = "left" }
                used = 0
            end
            table.insert(cur, w)
            used = used + wh
        end
    end
    if #cur > 1 or #pages == 0 then
        table.insert(pages, cur)
    end
    return pages
end

--- 规范化页码到 [1, pages]
function Pager.clamp(page, pages)
    page = tonumber(page) or 1
    pages = math.max(1, tonumber(pages) or 1)
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    return page, pages
end

--- 三带布局：顶(可选) + 内容区 + 分页带
function Pager.frame(width, height, opts)
    opts = opts or {}
    local page, pages = Pager.clamp(opts.page, opts.pages)
    local band_h = Pager.bandH()
    local top = opts.top
    local top_h = 0
    if top then
        top_h = top.dimen and top.dimen.h or (top.getSize and top:getSize().h) or 0
    end
    local body_h = math.max(1, height - top_h - band_h)
    local body = opts.body
    if body and body.dimen then
        body.dimen.w = width
        body.dimen.h = body_h
    end

    local kids = { align = "left" }
    if top then
        table.insert(kids, top)
    end
    table.insert(kids, CenterContainer:new{
        dimen = Geom:new{ w = width, h = body_h },
        body or VerticalSpan:new{ width = body_h },
    })
    table.insert(kids, Pager.band(width, page, pages, opts.handlers or {}))

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = height },
        VerticalGroup:new(kids),
    }, body_h
end

return Pager
