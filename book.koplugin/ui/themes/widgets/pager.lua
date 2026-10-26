--[[--
主题翻页条：按钮、按键与左右滑动共用分页回调；循环由 ui.pager_cycle 控制。

  [<]        3 / 12        [>]
  [<]      ·  ●  ·  ·      [>]    dots=true（页数少的首页类场景）
  [<]         概览         [>]    title 给了就代替页码（分页有名字的场景）
  [<]      2026年9月       [>]    只给 title 不给 page/pages：无界翻页（月份），两侧常亮
  [<]   [+添加] [完成]     [>]    center 给了就放任意控件（优先于 dots / title）

  Pager.widget({ width = w, page = 3, pages = 12, on_page = fn, range = modal.dimen })
  range 扩大左右滑动范围；keys=false 用于同屏次级分页（月份等），不抢窗口翻页键和映射。

@module koplugin.book.ui.themes.widgets.pager
--]]

require("l10n").apply()

local CenterContainer = require("ui/widget/container/centercontainer")
local BD = require("ui/bidi")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Input = require("ui.input")
local Settings = require("utils.settings")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookThemePager
local Pager = {}

local PagerInput = InputContainer:extend{}

function PagerInput:init()
    if self.opts.keys ~= false then
        self.key_events.PagerNext = { { { "RPgFwd", "LPgFwd" } }, event = "PagerKey", args = 1 }
        self.key_events.PagerPrev = { { { "RPgBack", "LPgBack" } }, event = "PagerKey", args = -1 }
    end
    if self.opts.range then
        self.ges_events.PagerSwipe = { GestureRange:new{ ges = "swipe", range = self.opts.range } }
    end
end

function PagerInput:onBookWindowPage(dir)
    if self.opts.keys == false or not Input.isTop(self) then return false end
    self:turn(dir)
    return true
end

function PagerInput:onPagerKey(dir)
    if Settings.get("ui").pager_keys == false then return false end
    return self:onBookWindowPage(dir)
end

function PagerInput:onPagerSwipe(_arg, ges)
    if Settings.get("ui").pager_swipe == false or not Input.isTop(self) then return false end
    local dir = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if dir ~= "west" and dir ~= "east" then return false end
    self:turn(dir == "west" and 1 or -1)
    return true
end

function PagerInput:turn(dir)
    local opts = self.opts
    if opts.on_page then
        local page = Input.page(opts.page + dir, opts.pages, opts.cycle)
        if page ~= opts.page then opts.on_page(page) end
    elseif dir > 0 then
        opts.on_next()
    else
        opts.on_prev()
    end
end

--- 页码圆点：当前页强调色，其余 disabled；形状跟 control.radius（直角主题是方点）。
---@param t table 主题令牌
---@param page integer
---@param pages integer
---@return table
local function dots(t, page, pages)
    local size, gap = Theme.px(t.space.sm), Theme.px(t.space.sm)
    local row = HorizontalGroup:new{ align = "center" }
    for i = 1, pages do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Box:new{
            style = { bg = i == page and t.color.accent or t.color.disabled, radius = t.control.radius },
            width = size,
            height = size,
        }
    end
    return row
end

---@param opts table width/page/pages/on_page（有界）或 on_prev/on_next（无界）/dots/title/center/range/keys
---@return table
function Pager.widget(opts)
    local t = Theme.current()
    local h = Theme.px(t.control.height)
    local mid_w = math.max(1, opts.width - h * 2)
    local center = opts.center or opts.dots and dots(t, opts.page, opts.pages)
        or Text.line("body", opts.title or T(_("%1 / %2"), opts.page, opts.pages),
            { width = mid_w, color = opts.title and t.color.accent or t.color.ink })
    local input = PagerInput:new{ opts = opts }
    local cycle = opts.on_page and opts.cycle ~= false and Settings.get("ui").pager_cycle and opts.pages > 1
    input[1] = HorizontalGroup:new{
        align = "center",
        Button:new{ icon = "chevron_left", variant = "ghost", width = h, height = h,
            enabled = cycle or not opts.page or opts.page > 1, callback = function() input:turn(-1) end },
        CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = h }, center },
        Button:new{ icon = "chevron_right", variant = "ghost", width = h, height = h,
            enabled = cycle or not opts.pages or opts.page < opts.pages, callback = function() input:turn(1) end },
    }
    return input
end

return Pager
