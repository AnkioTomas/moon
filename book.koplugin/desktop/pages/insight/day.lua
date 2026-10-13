--[[--
统计页第 2 页：选中日期的阅读书单。

@module koplugin.book.desktop.pages.insight.day
--]]

local Book = require("ui.widgets.book")
local Chart = require("ui.widgets.chart")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Progress = require("ui.themes.widgets.progress")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightDay
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
function Day:build(desktop, state, width, avail_h, open_book)
    local t = Theme.current()
    local selected = state.selected or ""
    local days = state.calendar.days
    local info = selected ~= "" and days[selected] or nil
    local books = info and info.books or {}
    local xs, sm, md = Theme.px(t.space.xs), Theme.px(t.space.sm), Theme.px(t.space.md)
    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    --- 追加控件并累计高度，用于在可用区域内截断书单。
    ---@param widget table 子控件。
    local function push(widget)
        col[#col + 1] = widget
        used = used + widget:getSize().h
    end
    ---@param text string
    ---@return table
    local function muted(text)
        return Text.line("caption", text, { width = width, color = t.color.muted })
    end

    local title = selected == "" and _("选择日期")
        or dayTitle(selected, info and info.duration_text or nil)
    push(Text.line("title", title, { width = width }))
    push(VerticalSpan:new{ width = md })
    if info and info.hours then
        push(muted(_("阅读时段")))
        push(VerticalSpan:new{ width = xs })
        push(Chart.bars({
            points = require("desktop.pages.insight.hours").points(info.hours),
            width = width, height = Theme.px(56), gap = Theme.px(2),
        }))
        push(VerticalSpan:new{ width = md })
    end

    if #books == 0 then
        push(muted(_("这一天没有阅读记录")))
        return col
    end

    local cover_w, cover_h = Theme.px(44), Theme.px(66)
    local more_h, shown = muted("0"):getSize().h, 0
    local plugin, api = desktop.plugin, desktop.source
    for i, book in ipairs(books) do
        local need = cover_h + (shown > 0 and md or 0)
        local reserve = (i < #books) and (xs + more_h) or 0
        if avail_h and used + need + reserve > avail_h then break end
        if shown > 0 then push(VerticalSpan:new{ width = md }) end

        local author_text = (book.authors and book.authors ~= "") and book.authors or _("未知作者")
        if book.duration_text and book.duration_text ~= "" then
            author_text = T(_("%1 · %2"), author_text, book.duration_text)
        end
        local cover = Book.cover(plugin, api, book, cover_w, cover_h, {
            badge = false,
            show_parent = desktop,
        })
        local meta_w = math.max(1, width - cover_w - md)
        local meta = VerticalGroup:new{
            align = "left",
            Text.line("body", book.title or book.stable_id or "?", { width = meta_w }),
            VerticalSpan:new{ width = xs },
            Text.line("caption", author_text, { width = meta_w, color = t.color.muted }),
            VerticalSpan:new{ width = sm },
            Progress:new{ width = meta_w, percent = book.percent },
        }
        push(Tap.wrap(HorizontalGroup:new{
            align = "center",
            cover,
            HorizontalSpan:new{ width = md },
            LeftContainer:new{ dimen = Geom:new{ w = meta_w, h = cover_h }, meta },
        }, function() open_book(book) end))
        shown = shown + 1
    end

    local rest = #books - shown
    if rest > 0 then
        push(VerticalSpan:new{ width = xs })
        push(muted(T(_("另有 %1 本未显示"), rest)))
    end
    return col
end

return Day
