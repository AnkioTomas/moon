--[[--
左右翻页容器：两侧小箭头夹住内容。单页时退化为纯 child，不占箭头位。

布局（多页）：
  +-----+---------------------------+-----+
  |  ‹  |         child             |  ›  |
  +-----+---------------------------+-----+

@module koplugin.book.ui.components.pagecontainer
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")

---@class BookPageContainer
local PageContainer = {}

--- 单侧箭头占位宽度。
---@return number
function PageContainer.sideW()
    return UI.sz(28)
end

--- 多页时内容区可用宽；单页返回总宽。
---@param width number
---@param pages number|nil
---@return number
function PageContainer.contentWidth(width, pages)
    width = math.max(1, math.floor(tonumber(width) or 1))
    if (tonumber(pages) or 1) <= 1 then return width end
    return math.max(1, width - PageContainer.sideW() * 2)
end

--- 规范化页码。
---@param page number|nil
---@param pages number|nil
---@return integer, integer
function PageContainer.clamp(page, pages)
    pages = math.max(1, math.floor(tonumber(pages) or 1))
    page = math.max(1, math.floor(tonumber(page) or 1))
    return math.min(page, pages), pages
end

---@param name string
---@param enabled boolean
---@param on_tap fun()|nil
---@return table
local function arrow(name, enabled, on_tap)
    local size = PageContainer.sideW()
    local tap = InputContainer:new{ dimen = Geom:new{ w = size, h = size } }
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        Icon.widget{
            name = name,
            size = 18,
            color = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9,
        },
    }
    if not enabled or not on_tap then return tap end
    tap.ges_events = {
        TapPageContainer = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapPageContainer = function()
        on_tap()
        return true
    end
    return tap
end

--- 包一层左右翻页。pages≤1 时原样返回 child。
---@param opts {
---   child: table,
---   width: number,
---   page: number|nil,
---   pages: number|nil,
---   on_prev: fun()|nil,
---   on_next: fun()|nil,
--- }
---@return table
function PageContainer.wrap(opts)
    local page, pages = PageContainer.clamp(opts.page, opts.pages)
    local child = opts.child
    if pages <= 1 then return child end
    local width = math.max(1, math.floor(tonumber(opts.width) or 1))
    local side = PageContainer.sideW()
    local mid = math.max(1, width - side * 2)
    local h = math.max(side, child:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = side, h = h },
            arrow("chevron_left", page > 1, opts.on_prev),
        },
        CenterContainer:new{
            dimen = Geom:new{ w = mid, h = h },
            child,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = side, h = h },
            arrow("chevron_right", page < pages, opts.on_next),
        },
    }
end

return PageContainer
