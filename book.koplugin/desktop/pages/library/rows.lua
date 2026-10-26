--[[--
图书馆列表视图的行：书行与分组行（作者 / 系列 / 分类）。

  +------------------------------------------------------+
  | +----+ 书名                                          |
  | |封面| 作者                            [已下载]  ⋮   |
  | |    | 系列                                          |
  | +----+ [██████████··············]  42%              |
  +------------------------------------------------------+

书行整行点开书（打开中的状态条盖在封面上），⋮ 进详情；进度条拉到右侧列为止，
已读显示「已读完」、没读显示「未读」，都不画条。分组行是主题 Row：名称 + 「N 本书」。

@module koplugin.book.desktop.pages.library.rows
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Book = require("ui.widgets.book")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Icon = require("ui.themes.widgets.icon")
local Progress = require("ui.themes.widgets.progress")
local Row = require("ui.themes.widgets.row")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

local Rows = {}

--- 书行底部：进度条 + 百分比，已读 / 未读只给文字。
---@param book Book
---@param w number
---@param t table 主题
---@return table
local function progressLine(book, w, t)
    local muted = { color = t.color.muted }
    if Book.isRead(book) then return Text.line("caption", _("已读完"), muted) end
    local pct = Book.pct(book)
    if pct <= 0 then return Text.line("caption", _("未读"), muted) end
    local label = Text.line("caption", string.format("%.0f%%", pct), muted)
    local gap = Theme.px(t.space.sm)
    return HorizontalGroup:new{
        align = "center",
        Progress:new{ width = math.max(1, w - gap - label:getSize().w), percent = pct },
        HorizontalSpan:new{ width = gap },
        label,
    }
end

--- 书行。
---@param ctx table 构建上下文（plugin / source / desktop）
---@param book Book
---@param w number 行宽
---@param h number 行高（含分隔线）
---@param on_open fun(book: Book, cover: table, cw: number, ch: number)
---@param on_detail fun(book: Book)
---@return table
function Rows.book(ctx, book, w, h, on_open, on_detail)
    local t = Theme.current()
    local pad, gap = Theme.px(t.space.md), Theme.px(t.space.md)
    local rule = Theme.px(t.row.divider)
    local inner_h = h - rule
    local ch = inner_h - Theme.px(t.space.sm) * 2
    local cw = math.floor(ch * 2 / 3)
    -- 打开中的状态条要追加到封面子件里，Book.cover 无角标时只返回 Box，统一包一层。
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = cw, h = ch },
        (Book.cover(ctx.plugin, ctx.source, book, cw, ch, { show_parent = ctx.desktop })),
    }

    local more_w = Theme.px(t.control.height)
    local more = Book.tappable(more_w, inner_h, function() on_detail(book) end)
    more[1] = CenterContainer:new{
        dimen = Geom:new{ w = more_w, h = inner_h },
        Icon.widget{ name = "more_vert", size = t.control.icon, color = Theme.color(t.color.icons) },
    }
    local side = HorizontalGroup:new{ align = "center" }
    if book.downloaded then
        side[1] = Box:new{
            style = { border = 1, border_color = t.color.ink },
            padding = Theme.px(t.space.xs),
            Text.line("caption", _("已下载")),
        }
    end
    side[#side + 1] = more
    local side_w = 0
    for _idx, child in ipairs(side) do side_w = side_w + child:getSize().w end

    local mid_w = math.max(1, w - pad * 2 - cw - gap * 2 - side_w)
    local meta = VerticalGroup:new{
        align = "left",
        Text.line("body", Book.title(book), { width = mid_w, bold = true, color = t.color.headings }),
    }
    local author = Book.author(book)
    meta[2] = Text.line("caption", author ~= "" and author or _("未知作者"), { width = mid_w, color = t.color.muted })
    if book.series and book.series ~= "" then
        meta[3] = Text.line("caption", book.series, { width = mid_w, color = t.color.muted })
    end
    local bottom = progressLine(book, mid_w, t)
    local mid_h = math.max(ch, meta:getSize().h + bottom:getSize().h)
    -- Text.line 的 width 只是上限，不固定宽度时右侧列会随书名长短漂移。
    local mid = LeftContainer:new{
        dimen = Geom:new{ w = mid_w, h = mid_h },
        VerticalGroup:new{
            align = "left",
            meta,
            VerticalSpan:new{ width = mid_h - meta:getSize().h - bottom:getSize().h },
            bottom,
        },
    }

    local row = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            cover,
            HorizontalSpan:new{ width = gap },
            mid,
            HorizontalSpan:new{ width = gap },
            side,
            HorizontalSpan:new{ width = pad },
        },
        LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = w, h = rule },
        },
    }
    return Tap.wrap(Box:new{ style = {}, width = w, height = h, row }, function()
        on_open(book, cover, cw, ch)
    end)
end

--- 分组行高（含分隔线）。
---@return number
function Rows.groupHeight()
    return Row.height(false) + Theme.px(Theme.current().row.divider)
end

--- 分组行：名称 + 「N 本书」+ 箭头。
---@param name string
---@param count number
---@param w number
---@param on_tap fun()
---@return table
function Rows.group(name, count, w, on_tap)
    return Row.widget{
        width = w,
        title = name,
        status = T(_("%1 本书"), count),
        callback = on_tap,
    }
end

return Rows
