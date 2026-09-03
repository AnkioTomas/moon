--[[--
统计页第 2 页：选中日期的阅读书单。

@module koplugin.book.ui.desktop.insight.day
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local Day = {}

--- 构建日期标题，可附带该日阅读时长。
---@param ymd string YYYY-MM-DD 日期键。
---@param duration_text string|nil 时长文案。
---@return string
local function dayTitle(ymd, duration_text)
    local _year, month, day = ymd:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not month then return ymd end
    local date = T(_("%1月%2日"), tonumber(month), tonumber(day))
    if duration_text and duration_text ~= "" then
        return T(_("%1 · %2"), date, duration_text)
    end
    return date
end

--- 构建当日书单详情页。
---@param desktop table 桌面实例。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param avail_h number 可用高度。
---@param open_book fun(book: table) 打开书籍详情的回调。
---@return table
function Day.build(desktop, state, width, avail_h, open_book)
    local selected = state.selected or ""
    local days = (state.calendar and state.calendar.days) or {}
    local info = selected ~= "" and days[selected] or nil
    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    --- 追加控件并累计高度，用于在可用区域内截断书单。
    ---@param widget table 子控件。
    ---@param widget_h number 控件高度。
    local function push(widget, widget_h)
        table.insert(col, widget)
        used = used + (widget_h or 0)
    end

    local title = selected == "" and _("选择日期")
        or dayTitle(selected, info and info.duration_text or nil)
    local title_widget = TextWidget:new{
        text = title,
        face = UI.face("cfont", 15),
        max_width = width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    push(title_widget, title_widget:getSize().h)
    push(VerticalSpan:new{ width = UI.sz(10) }, UI.sz(10))

    if not info or not info.books or #info.books == 0 then
        local empty = UI.mutedText(_("这一天没有阅读记录"), width)
        push(empty, empty:getSize().h)
        return col
    end

    local cover_w, cover_h = UI.sz(44), UI.sz(66)
    local gap, row_gap = UI.sz(12), UI.sz(12)
    local more_h, shown = UI.sz(22), 0
    local plugin, api = desktop.plugin, desktop.source
    for i, book in ipairs(info.books) do
        local need = cover_h + (shown > 0 and row_gap or 0)
        local reserve = (i < #info.books) and (UI.sz(6) + more_h) or 0
        if avail_h and used + need + reserve > avail_h then break end
        if shown > 0 then push(VerticalSpan:new{ width = row_gap }, row_gap) end

        local sid = book.stable_id
        local title_text = book.title or sid or "?"
        local author_text = (book.authors and book.authors ~= "") and book.authors or _("未知作者")
        local percent = tonumber(book.percent) or 0
        if percent < 0 then percent = 0 elseif percent > 100 then percent = 100 end
        local cover = select(1, BookInfo.cover(plugin, api, book, cover_w, cover_h, {
            badge = false,
            show_parent = desktop,
        }))
        local meta_w = math.max(1, width - cover_w - gap)
        local meta = VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = title_text,
                face = UI.face("cfont", 14),
                max_width = meta_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(4) },
            UI.mutedText(author_text, meta_w, 12),
            VerticalSpan:new{ width = UI.sz(8) },
            UI.progressBar(meta_w, UI.sz(6), percent),
        }
        local tap = BookInfo.tappable(width, cover_h, function()
            open_book(book)
        end)
        tap[1] = HorizontalGroup:new{
            align = "center",
            cover,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{ dimen = Geom:new{ w = meta_w, h = cover_h }, meta },
        }
        push(tap, cover_h)
        shown = shown + 1
    end

    local rest = #info.books - shown
    if rest > 0 then
        push(VerticalSpan:new{ width = UI.sz(6) }, UI.sz(6))
        local more = UI.mutedText(T(_("另有 %1 本未显示"), rest), width)
        push(more, more:getSize().h)
    end
    return col
end

return Day
