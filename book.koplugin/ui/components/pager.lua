--[[--
统一「Page X of Y」翻页条。桌面各页禁止 ScrollableContainer，溢出用本组件。

间距按可用宽度收缩，避免超大分辨率 / 大 ui_scale 下两侧按钮溢出。

布局：

  widget / band
  +-----------------------------------------------+
  |  |«  ‹   Page N of M   ›  »|                  |
  |                    ↑贴底 padding              |
  +-----------------------------------------------+

  frame（顶可选 + 内容顶对齐 + 分页贴底）
  +-----------------------------------------------+
  | [top?]                                        |
  | body…                                         |
  |                                               |
  |  |«  ‹   Page N of M   ›  »|                  |
  +-----------------------------------------------+

@module koplugin.book.ui.components.pager
--]]

local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local Pager = {}

--- 底部分页带高度（含贴底 padding）。
---@return number
function Pager.bandH()
    return UI.iconSz() + UI.sz(32)
end

--- 按 avail_w 算图标边长与间距，保证 4 键 + 页码不撑破宽度。
---@param avail_w number
---@param info_w number
---@return number, number, number
local function fitMetrics(avail_w, info_w)
    avail_w = math.max(1, tonumber(avail_w) or Screen:getWidth())
    info_w = math.max(0, tonumber(info_w) or 0)
    local pad = UI.sz(2)
    local prefer_icon = UI.iconSz()
    local prefer_gap = UI.sz(32)
    local min_icon = math.max(1, Screen:scaleBySize(14))
    local min_gap = 0

    --- 估算整行占用宽度。
    ---@param icon number
    ---@param gap number
    ---@return number
    local function total(icon, gap)
        return 4 * (icon + pad * 2) + 4 * gap + info_w
    end

    local icon = prefer_icon
    local gap = prefer_gap
    if total(icon, gap) > avail_w then
        gap = math.floor((avail_w - 4 * (icon + pad * 2) - info_w) / 4)
        if gap < min_gap then
            gap = min_gap
            icon = math.floor((avail_w - info_w - 4 * gap) / 4) - pad * 2
            if icon < min_icon then
                icon = min_icon
            end
            if icon > prefer_icon then
                icon = prefer_icon
            end
        elseif gap > prefer_gap then
            gap = prefer_gap
        end
    end
    return icon, gap, pad
end

--- 与官方 Menu 底栏一致：首/上/页码/下/末。
---@param page number
---@param pages number
---@param handlers table|nil
---@param width number|nil 可用宽度；缺省用屏宽
---@return table
function Pager.widget(page, pages, handlers, width)
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

    local avail = tonumber(width) or Screen:getWidth()
    local icon_sz, gap, pad = fitMetrics(avail, info:getSize().w)
    local spacers = {}
    for i = 1, 4 do
        spacers[i] = HorizontalSpan:new{ width = gap }
    end

    --- 构建翻页箭头按钮。
    ---@param icon string
    ---@param cb fun()|nil
    ---@return table
    local function chev(icon, cb)
        return Button:new{
            icon = icon,
            icon_width = icon_sz,
            icon_height = icon_sz,
            bordersize = 0,
            padding = pad,
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
    first:enableDisable(page > 1)
    left:enableDisable(page > 1)
    right:enableDisable(page < pages)
    last:enableDisable(page < pages)

    local row = HorizontalGroup:new{
        first,
        spacers[1],
        left,
        spacers[2],
        info,
        spacers[3],
        right,
        spacers[4],
        last,
    }
    -- 按钮真实宽度可能大于估算，再收一档
    local row_w = row:getSize().w
    if row_w > avail and gap > 0 then
        gap = math.max(0, gap - math.ceil((row_w - avail) / 4))
        for i = 1, 4 do
            spacers[i].width = gap
        end
    end
    return row
end

--- 固定高度的分页带：控件贴底，与桌面底栏留出空隙。
---@param width number
---@param page number
---@param pages number
---@param handlers table|nil
---@return table
function Pager.band(width, page, pages, handlers)
    local bottom_pad = UI.sz(14)
    local band_h = Pager.bandH()
    return BottomContainer:new{
        dimen = Geom:new{ w = width, h = band_h },
        VerticalGroup:new{
            align = "center",
            Pager.widget(page, pages, handlers, width),
            VerticalSpan:new{ width = bottom_pad },
        },
    }
end

--- 把已测量的 widget 列表按 avail_h 切成多页（每页一个 VerticalGroup 的 kids 表）。
---@param widgets table|nil
---@param avail_h number
---@return table
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

--- 规范化页码到 [1, pages]。
---@param page number|nil
---@param pages number|nil
---@return number, number
function Pager.clamp(page, pages)
    page = tonumber(page) or 1
    pages = math.max(1, tonumber(pages) or 1)
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    return page, pages
end

--- 三带布局：顶(可选) + 内容区 + 分页带。
---@param width number
---@param height number
---@param opts table|nil
---@return table, number
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
    -- 内容顶对齐，分页条贴底（与 home 一致；禁止垂直居中）
    table.insert(kids, TopContainer:new{
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
