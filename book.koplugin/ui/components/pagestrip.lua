--[[--
首页翻页条：两侧上一页/下一页，中间圆点或标题。不用 Pager。

@module koplugin.book.ui.components.pagestrip
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local logger = require("utils.log")
local _ = require("gettext")

---@class BookPageStrip
local PageStrip = {}

--- 返回翻页条占用的缩放后高度，供首页预留布局空间。
---@return number height 翻页条高度，单位像素
function PageStrip.bandH()
    return UI.sz(40)
end

--- 构建翻页侧按钮；不可翻页时仅显示淡色图标，不注册点击事件。
---@param name string 区域、组件或图标名称
---@param enabled boolean 按钮是否可点击
---@param on_tap fun() 点击命中区域时执行的回调
---@return table
local function sideButton(name, enabled, on_tap)
    logger.dbg("page strip button", name, enabled and "enabled" or "disabled")
    local size = UI.sz(36)
    local tap = InputContainer:new{ dimen = Geom:new{ w = size, h = size } }
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        Icon.widget{
            name = name,
            size = 22,
            -- 使用可见度更高的浅灰；UI.muted() 的 0x33 在部分屏幕上接近黑色。
            color = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9,
        },
    }
    if not enabled then return tap end
    tap.ges_events = {
        TapPageStrip = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapPageStrip = function()
        logger.dbg("page strip tap", name)
        on_tap()
        return true
    end
    return tap
end

--- 构建居中的分页指示点，用深色标记当前页。
---@param page number 当前页码，从 1 开始
---@param pages number 总页数
---@param width number 目标宽度，单位像素
---@return table
local function dotsCenter(page, pages, width)
    local kids = { align = "center" }
    local dot = UI.sz(8)
    local gap = UI.sz(6)
    for i = 1, pages do
        if i > 1 then table.insert(kids, HorizontalSpan:new{ width = gap }) end
        local active = i == page
        table.insert(kids, LineWidget:new{
            background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{ w = dot, h = dot },
        })
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = PageStrip.bandH() },
        HorizontalGroup:new(kids),
    }
end

--- 构建翻页条中央标题；提供回调时将标题包装为点击区域。
---@param title string 显示标题
---@param width number 目标宽度，单位像素
---@param on_tap fun()|nil 点击命中区域时执行的回调
---@return table
local function titleCenter(title, width, on_tap)
    local label = TextWidget:new{
        text = title,
        face = UI.face("cfont", 14),
        max_width = width,
    }
    local box = CenterContainer:new{
        dimen = Geom:new{ w = width, h = PageStrip.bandH() },
        label,
    }
    if not on_tap then return box end
    local tap = InputContainer:new{ dimen = Geom:new{ w = width, h = PageStrip.bandH() } }
    tap[1] = box
    tap.ges_events = {
        TapPageStripTitle = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapPageStripTitle = function()
        on_tap()
        return true
    end
    return tap
end

--- 拼一条翻页带。 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@param opts {
---   width: number,
---   page: number,
---   pages: number,
---   center?: "dots"|"title",
---   title?: string,
---   on_prev?: fun(),
---   on_next?: fun(),
---   on_center?: fun(),
--- }
---@return table
function PageStrip.widget(opts)
    local width = math.max(1, math.floor(tonumber(opts.width) or 1))
    local page = math.max(1, math.floor(tonumber(opts.page) or 1))
    local pages = math.max(1, math.floor(tonumber(opts.pages) or 1))
    page = math.min(page, pages)
    logger.dbg("page strip build", "page", page, "pages", pages,
        "prev", page > 1, "next", page < pages,
        "center", opts.center or "dots")
    local band_h = PageStrip.bandH()
    local side_w = UI.sz(44)
    local mid_w = math.max(1, width - side_w * 2)

    local center
    if opts.center == "title" then
        center = titleCenter(opts.title or _("完成"), mid_w, opts.on_center)
    else
        center = dotsCenter(page, pages, mid_w)
    end

    local row = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = side_w, h = band_h },
            sideButton("chevron_left", page > 1, opts.on_prev or function() end),
        },
        center,
        CenterContainer:new{
            dimen = Geom:new{ w = side_w, h = band_h },
            sideButton("chevron_right", page < pages, opts.on_next or function() end),
        },
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = width,
        height = band_h,
        dimen = Geom:new{ w = width, h = band_h },
        row,
    }
end

return PageStrip
