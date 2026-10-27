--[[-- 书籍详情：头部（封面 + 书名 / 主按钮 / 进度）、指标带、简介、书籍信息表。 @module desktop.detail --]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local T = require("ffi/util").template
local Catalog = require("book.catalog")
local Book = require("ui.widgets.book")
local Theme = require("ui.themes")
local Button = require("ui.themes.widgets.button")
local Progress = require("ui.themes.widgets.progress")
local Sheet = require("ui.themes.widgets.sheet")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local TextViewer = require("ui.themes.widgets.text_viewer")
local _ = require("gettext")

local Common = require("desktop.detail.common")

-- 「阅读记录」里列出的天数；估算读完日期仍用 loadStats 取的全部记录。
local RECENT_DAYS = 14

--- 头部第四行：「★ 9.6 微信读书 · 43.2 万字」；都没有返回 nil。
---@param m BookMeta
---@return string|nil
local function scoreLine(m)
    local parts = {}
    if m.rating then
        local by = ({ weread = _("微信读书"), douban = _("豆瓣") })[m.rating.by] or m.rating.by
        parts[1] = string.format("★ %.1f", m.rating.score) .. (by and " " .. by or "")
    end
    local words = m.words
    if words then
        parts[#parts + 1] = words >= 10000 and T(_("%1 万字"), string.format("%.1f", words / 10000))
            or T(_("%1 字"), words)
    end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

--- 书籍信息表的条目：{ 标签, 值, 独占一行 }。格式、大小、文件名只有整本书文件（或书城条目）才有。
---@return table[]
local function infoItems(book, owner)
    local sid = book.source_id
    local path = owner and owner.type == "book" and book.path or nil
    local name = path and path:match("[^/]+$")
    local format = book.format or (name and name:match("%.(%w+)$"))
    local size = tonumber(book.filesize) or (path and require("libs/libkoreader-lfs").attributes(path, "size"))
    local added = tonumber(book.inserted_at) or 0
    local m = book.meta or {}
    local items = {}
    for _idx, item in ipairs({
        { _("来源"), sid == "zlib" and _("Z站") or sid == "opds" and _("OPDS")
            or sid and ((require("source.registry").meta(sid) or {}).name or sid) },
        { _("格式"), format and format:upper() },
        { _("大小"), size and size > 0 and require("util").getFriendlySize(size) },
        { _("加入"), added > 0 and os.date("%Y-%m-%d", added) },
        { _("语言"), m.language and ({ zh = _("中文"), en = _("英文"), ja = _("日文") })[m.language] or m.language },
        { "ISBN", m.isbn },
        { _("文件"), name, true },
    }) do
        if item[2] and item[2] ~= "" then items[#items + 1] = item end
    end
    return items
end

--- 两列「标签 值」表；独占项单独一行。超出 max_h 的行从末尾整行丢弃。
---@param items table[]
---@param w number 物理像素
---@param max_h number
---@return table
local function infoTable(items, w, max_h)
    local t = Theme.current()
    local gap = Theme.px(t.space.sm)
    local label_w = Theme.px(t.font.caption * 3)
    local col_w = math.floor((w - gap) / 2)
    local function cell(item, cw)
        local label = Text.line("caption", item[1], { color = t.color.muted })
        local row = HorizontalGroup:new{
            align = "center",
            label,
            HorizontalSpan:new{ width = math.max(0, label_w - label:getSize().w) },
            Text.line("body", item[2], { width = math.max(1, cw - label_w) }),
        }
        return LeftContainer:new{ dimen = Geom:new{ w = cw, h = row:getSize().h }, row }
    end
    local rows, half = {}, nil
    for _idx, item in ipairs(items) do
        if half and not item[3] then
            rows[#rows] = HorizontalGroup:new{ align = "center", half, HorizontalSpan:new{ width = gap }, cell(item, col_w) }
            half = nil
        else
            half = not item[3] and cell(item, col_w) or nil
            rows[#rows + 1] = half or cell(item, w)
        end
    end
    local table_w = VerticalGroup:new{ align = "left" }
    local used = 0
    for _idx, row in ipairs(rows) do
        local need = row:getSize().h + (used > 0 and gap or 0)
        if used + need > max_h then break end
        if used > 0 then table_w[#table_w + 1] = VerticalSpan:new{ width = gap } end
        table_w[#table_w + 1] = row
        used = used + need
    end
    return table_w
end

--- 详情页分隔线比主题 rule 淡一半（往白色靠），页面上线多，用全色太抢眼。
---@return table Blitbuffer.Color8
local function ruleColor()
    local rule = Theme.current().color.rule
    return Blitbuffer.Color8(rule + math.floor((0xFF - rule) / 2))
end

--- 节与节之间的细分隔线。
---@param w number
---@return table
local function divider(w)
    local t = Theme.current()
    return LineWidget:new{
        background = ruleColor(),
        dimen = Geom:new{ w = w, h = math.max(1, Theme.px(t.row.divider)) },
    }
end

---@param ts number|nil
---@param fmt string
---@return string
local function date(ts, fmt)
    return ts and ts > 0 and os.date(fmt, ts) --[[@as string]] or "—"
end

--- 指标带用的短日期：今年只给月-日，其余年份带年。
---@param ts number|nil
---@return string
local function shortDate(ts)
    return date(ts, ts and os.date("%Y", ts) == os.date("%Y") and "%m-%d" or "%Y-%m-%d")
end

--- 按进度比例外推剩余时长；读完日期见 require("utils.forecast").finishDate。
---@param percent number 0..100
---@param total_seconds number 累计时长
---@param daily table[] StatsDB.dailyByBook（日期倒序）
---@return number|nil remaining 秒；没开始或已读完为 nil
---@return number|nil finish 读完日期的时间戳；没有近期记录为 nil
local function estimate(percent, total_seconds, daily)
    local fraction = percent / 100
    if fraction <= 0 or fraction >= 1 or total_seconds <= 0 then return nil end
    local remaining = math.floor(total_seconds * (1 - fraction) / fraction)
    return remaining, require("utils.forecast").finishDate(remaining, daily)
end

--- 一行三张 KPI 卡。
---@param w number
---@param gap number
---@param items string[][] { 数值, 说明 }
---@return table
local function kpiRow(w, gap, items)
    local cell_w = math.floor((w - gap * 2) / 3)
    local row = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Common.kpiCard(cell_w, item[1], item[2])
    end
    return row
end

return function(Detail)
--- 本书的预计剩余时长与读完日期，见 estimate。
---@return number|nil, number|nil
function Detail:forecast()
    local st = self._stats
    if not st then return nil end
    return estimate(tonumber(self.book.percent) or 0, st.total_seconds, self._daily or {})
end

--- 「NN%」+ 进度条 + 「约剩 X」（能估算时）。
---@param w number
---@param pct number
---@return table
function Detail:progressRow(w, pct)
    local t = self.theme
    local gap = Theme.px(t.space.sm)
    local label = Text.line("caption", string.format("%.0f%%", pct))
    local remaining = self:forecast()
    local tail = remaining and Text.line("caption", T(_("约剩 %1"), Catalog.formatDuration(remaining)),
        { color = t.color.muted })
    local bar_w = w - label:getSize().w - gap - (tail and tail:getSize().w + gap or 0)
    local row = HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = gap },
        Progress:new{ width = math.max(1, bar_w), percent = pct },
    }
    if tail then
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        row[#row + 1] = tail
    end
    return row
end

--- 头部：左封面（屏宽 38%），右栏书名 / 作者 / 系列·分类，主按钮与进度贴封面底边。
---@param w number 物理像素
---@param owner table|nil 属主源
---@param primary table|nil { icon, text, callback }
---@return table
function Detail:buildHead(w, owner, primary)
    local t = self.theme
    local book = self.book
    local gap = Theme.px(t.space.lg)
    local cw = math.floor(w * 0.38)
    local ch = math.floor(cw * 3 / 2)
    local cover = (Book.cover(self.plugin, owner, book, cw, ch, { badge = false, show_parent = self }))
    if primary and self.origin ~= "store" then
        local tap = Book.tappable(cw, ch, primary.callback)
        tap[1] = cover
        cover = tap
    end

    local sw = math.max(1, w - cw - gap)
    local small = Theme.px(t.space.xs)
    local author = Book.author(book)
    local top = VerticalGroup:new{
        align = "left",
        Text.box("title", Book.title(book), sw, { max_lines = 3, transparent = true }),
        VerticalSpan:new{ width = small },
        Text.line("body", author ~= "" and author or _("未知作者"), { width = sw }),
    }
    local tags = {}
    if book.series and book.series ~= "" then tags[#tags + 1] = book.series end
    if book.category and book.category ~= "" then tags[#tags + 1] = (book.category:gsub("[,\n]+", " · ")) end
    local m = book.meta or {}
    local pub = {}
    if m.publisher then pub[#pub + 1] = m.publisher end
    if m.published then pub[#pub + 1] = m.published end
    for _idx, line in ipairs({ table.concat(tags, " · "), table.concat(pub, " · ") }) do
        if line ~= "" then
            top[#top + 1] = VerticalSpan:new{ width = small }
            top[#top + 1] = Text.line("caption", line, { width = sw, color = t.color.muted })
        end
    end
    local score = scoreLine(m)
    if score then
        top[#top + 1] = VerticalSpan:new{ width = Theme.px(t.space.sm) }
        top[#top + 1] = Text.line("body", score, { width = sw })
    end

    local bottom = VerticalGroup:new{ align = "left" }
    if primary then
        bottom[1] = Button:new{ icon = primary.icon, text = primary.text, variant = "primary", width = sw,
            callback = primary.callback }
    end
    local pct = Book.pct(book)
    if self.origin ~= "store" and pct > 0 then
        if #bottom > 0 then bottom[#bottom + 1] = VerticalSpan:new{ width = Theme.px(t.space.sm) } end
        bottom[#bottom + 1] = self:progressRow(sw, pct)
    end
    local filler = math.max(Theme.px(t.space.md), ch - top:getSize().h - bottom:getSize().h)
    return HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = gap },
        VerticalGroup:new{ align = "left", top, VerticalSpan:new{ width = filler }, bottom },
    }
end

--- 指标带：四格「数值 / 说明」，竖线分隔，点按看阅读记录；无本机记录时单行占位。
--- 有云端时长但没有本机逐页记录的书（例如交给 kamare 打开阅读的漫画）也算有记录，
--- 不能因为 pages=0 就退化成「暂无阅读记录」。
---@param w number 物理像素
---@return table
function Detail:buildStats(w)
    local t = self.theme
    local st = self._stats
    local seconds = st and (tonumber(st.total_seconds) or 0) or 0
    local pages = st and (tonumber(st.pages) or 0) or 0
    if not st or (seconds <= 0 and pages <= 0) then
        return Text.line("body", _("暂无阅读记录"), { width = w, color = t.color.muted })
    end
    local _remaining, finish = self:forecast()
    local items = {
        { Catalog.formatDuration(seconds), _("累计时长") },
        { pages > 0 and tostring(pages) or "—", _("已读页数") },
        { shortDate(st.last_read), _("上次阅读") },
        finish and { shortDate(finish), _("预计读完") } or { shortDate(st.first_read), _("开始日期") },
    }
    local rule = math.max(1, Theme.px(t.row.divider))
    local cell_w = math.floor((w - rule * (#items - 1)) / #items)
    -- 大字号主题下带年份的日期放不进四分之一宽：整排一起降一档，不让单格截断。
    local role = "title"
    for _idx, item in ipairs(items) do
        local probe = Text.line("title", item[1])
        local fits = probe:getSize().w <= cell_w
        probe:free()
        if not fits then role = "body" break end
    end
    local row = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        local cell = VerticalGroup:new{
            align = "center",
            Text.line(role, item[1], { width = cell_w, bold = true }),
            VerticalSpan:new{ width = Theme.px(t.space.xs) },
            Text.line("caption", item[2], { width = cell_w, color = t.color.muted }),
        }
        local cell_h = cell:getSize().h
        if i > 1 then
            row[#row + 1] = LineWidget:new{
                background = ruleColor(),
                dimen = Geom:new{ w = rule, h = cell_h },
            }
        end
        row[#row + 1] = CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h }, cell }
    end
    return Tap.wrap(row, function() self:showRecords() end)
end

--- 阅读记录弹层：完整 KPI 两行三列 + 最近几天的时长条。
function Detail:showRecords()
    Sheet:new{
        title = _("阅读记录"),
        items = { { widget = function(width) return self:buildRecords(width) end } },
    }:show()
end

---@param w number 物理像素
---@return table
function Detail:buildRecords(w)
    local t = self.theme
    local st = self._stats
    local gap = Theme.px(t.space.sm)
    local remaining, finish = self:forecast()
    local pages = tonumber(st.pages) or 0
    local kids = VerticalGroup:new{
        align = "left",
        kpiRow(w, gap, {
            { Catalog.formatDuration(st.total_seconds), _("累计时长") },
            { pages > 0 and tostring(pages) or "—", _("已读页数") },
            { date(st.last_read, "%Y-%m-%d"), _("上次阅读") },
        }),
        VerticalSpan:new{ width = gap },
        kpiRow(w, gap, {
            { date(st.first_read, "%Y-%m-%d"), _("开始日期") },
            { remaining and Catalog.formatDuration(remaining) or "—", _("预计剩余") },
            { date(finish, "%Y-%m-%d"), _("预计读完") },
        }),
    }
    -- 阅读会话：云端拉回来的真实时段（本机交给 kamare 读的漫画、其它设备读的书都在这里）。
    local sessions = self._sessions or {}
    if #sessions > 0 then
        kids[#kids + 1] = VerticalSpan:new{ width = gap * 2 }
        kids[#kids + 1] = Text.line("caption", _("最近阅读"), { color = t.color.muted })
        local label_w, dur_w = Theme.px(120), Theme.px(72)
        for i = 1, math.min(#sessions, 8) do
            local s = sessions[i]
            local start = tonumber(s.start_time) or 0
            local text = start > 0
                and T("%1–%2", os.date("%m-%d %H:%M", start), os.date("%H:%M", start + (tonumber(s.duration) or 0)))
                or "—"
            local row_h = Theme.px(20)
            kids[#kids + 1] = HorizontalGroup:new{
                align = "center",
                LeftContainer:new{
                    dimen = Geom:new{ w = label_w, h = row_h },
                    Text.line("caption", text, { color = t.color.muted }),
                },
                HorizontalSpan:new{ width = gap },
                LeftContainer:new{
                    dimen = Geom:new{ w = dur_w, h = row_h },
                    Text.line("caption", Catalog.formatDuration(s.duration or 0)),
                },
            }
        end
    end
    local daily = self._daily or {}
    if #daily == 0 then return kids end
    kids[#kids + 1] = VerticalSpan:new{ width = gap * 2 }
    kids[#kids + 1] = Text.line("caption", _("最近几天"), { color = t.color.muted })
    -- 条形按列出的天数里最长的一天归一。
    local n = math.min(#daily, RECENT_DAYS)
    local max_s = 0
    for i = 1, n do max_s = math.max(max_s, daily[i].seconds) end
    local date_w, dur_w = Theme.px(52), Theme.px(72)
    local bar_w = math.max(1, w - date_w - dur_w - gap * 2)
    for i = 1, n do
        local r = daily[i]
        local _y, m, d = tostring(r.ymd):match("^(%d+)%-(%d+)%-(%d+)$")
        local label = Text.line("caption", m and (m .. "-" .. d) or tostring(r.ymd), { color = t.color.muted })
        local row_h = label:getSize().h + gap
        kids[#kids + 1] = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = date_w, h = row_h }, label },
            HorizontalSpan:new{ width = gap },
            Progress:new{ width = bar_w, percent = max_s > 0 and r.seconds / max_s * 100 or 0 },
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = dur_w, h = row_h },
                Text.line("caption", Catalog.formatDuration(r.seconds)),
            },
        }
    end
    return kids
end

--- 简介节：放得下就全文；放不下截断并在右下角给「更多」，点按看全文。连一行都放不下返回 nil。
---@param w number 物理像素
---@param max_h number
---@return table|nil
function Detail:buildIntro(w, max_h)
    local desc = Book.desc(self.book)
    if desc == "" then return nil end
    local t = self.theme
    local title = Common.sectionTitle(_("简介"), w)
    local gap = Theme.px(t.space.xs)
    local box_h = max_h - title:getSize().h - gap
    local box = Text.box("body", desc, w, { color = t.color.muted, transparent = true })
    if box:getSize().h <= box_h then
        return VerticalGroup:new{ align = "left", title, VerticalSpan:new{ width = gap }, box }
    end
    local line_h = box:getLineHeight()
    box:free()
    local more = Text.line("caption", _("更多") .. " ›", { bold = true })
    local more_h = more:getSize().h
    if box_h - more_h < line_h then return nil end
    return Tap.wrap(VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{ width = gap },
        Text.box("body", desc, w, { color = t.color.muted, height = box_h - more_h, ellipsis = true, transparent = true }),
        RightContainer:new{ dimen = Geom:new{ w = w, h = more_h }, more },
    }, function()
        TextViewer:new{ title = Book.title(self.book), text = desc }:show()
    end)
end

--- 正文：头部，下接各节（指标带 / 简介 / 书籍信息），节间细线分隔。
--- 书籍信息先给简介留出几行再排，放不下的行从末尾丢；简介吃剩下的高度。
---@param w number 物理像素
---@param h number 可用高度
---@param owner table|nil 属主源
---@param primary table|nil 主操作
---@return table
function Detail:buildBody(w, h, owner, primary)
    local t = self.theme
    local gap = Theme.px(t.space.md)
    local sep_h = gap * 2 + math.max(1, Theme.px(t.row.divider))
    local head = self:buildHead(w, owner, primary)
    local sections = {}
    local used = head:getSize().h
    if self.origin ~= "store" then
        sections[1] = self:buildStats(w)
        used = used + sep_h + sections[1]:getSize().h
    end

    local info
    local items = infoItems(self.book, owner)
    if #items > 0 then
        local title = Common.sectionTitle(_("书籍信息"), w)
        local title_h = title:getSize().h + Theme.px(t.space.xs)
        local reserve = Book.desc(self.book) ~= "" and sep_h + Theme.px(t.font.body) * 6 or 0
        local rows = infoTable(items, w, h - used - sep_h - title_h - reserve)
        if #rows > 0 then
            info = VerticalGroup:new{ align = "left", title, VerticalSpan:new{ width = Theme.px(t.space.xs) }, rows }
            used = used + sep_h + info:getSize().h
        end
    end
    sections[#sections + 1] = self:buildIntro(w, h - used - sep_h)
    sections[#sections + 1] = info

    local body = VerticalGroup:new{ align = "left", head }
    for _idx, section in ipairs(sections) do
        body[#body + 1] = VerticalSpan:new{ width = gap }
        body[#body + 1] = divider(w)
        body[#body + 1] = VerticalSpan:new{ width = gap }
        body[#body + 1] = section
    end
    return body
end
end
