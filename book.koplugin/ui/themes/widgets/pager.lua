--[[--
主题翻页条：两侧上一页 / 下一页，中间「N / M」或圆点。到头的一侧按钮置灰不可点。

  [<]        3 / 12        [>]
  [<]      ·  ●  ·  ·      [>]    dots=true（页数少的首页类场景）
  [<]         概览         [>]    title 给了就代替页码（分页有名字的场景）
  [<]      2026年9月       [>]    只给 title 不给 page/pages：无界翻页（月份），两侧常亮
  [<]   [+添加] [完成]     [>]    center 给了就放任意控件（优先于 dots / title）

  Pager.widget({ width = w, page = 3, pages = 12, on_prev = fn, on_next = fn, dots = false, title = nil })

@module koplugin.book.ui.themes.widgets.pager
--]]

require("l10n").apply()

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookThemePager
local Pager = {}

--- 页码圆点：当前页 ink，其余 disabled；形状跟 control.radius（直角主题是方点）。
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
            style = { bg = i == page and t.color.ink or t.color.disabled, radius = t.control.radius },
            width = size,
            height = size,
        }
    end
    return row
end

---@param opts table width/page/pages/on_prev/on_next/dots/title/center
---@return table
function Pager.widget(opts)
    local t = Theme.current()
    local h = Theme.px(t.control.height)
    local mid_w = math.max(1, opts.width - h * 2)
    local center = opts.center or opts.dots and dots(t, opts.page, opts.pages)
        or Text.line("body", opts.title or T(_("%1 / %2"), opts.page, opts.pages), { width = mid_w })
    return HorizontalGroup:new{
        align = "center",
        Button:new{ icon = "chevron_left", variant = "ghost", width = h, height = h,
            enabled = not opts.page or opts.page > 1, callback = opts.on_prev },
        CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = h }, center },
        Button:new{ icon = "chevron_right", variant = "ghost", width = h, height = h,
            enabled = not opts.pages or opts.page < opts.pages, callback = opts.on_next },
    }
end

return Pager
