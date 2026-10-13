--[[-- 书籍详情：Hero（图书馆含简介）与内容区（零碎信息 + 书城简介 / 本机阅读统计）。 @module desktop.detail --]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Catalog = require("book.catalog")
local Book = require("ui.widgets.book")
local Hero = require("ui.widgets.bookhero")
local Theme = require("ui.themes")
local Icon = require("ui.themes.widgets.icon")
local Pager = require("ui.themes.widgets.pager")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local TextViewer = require("ui.themes.widgets.text_viewer")
local _ = require("gettext")

local Common = require("desktop.detail.common")

--- Hero 下方的零碎信息，按显示优先级排：{ 图标, 文字 }。
--- 格式、大小、文件名只有整本书文件（或书城条目）才有。
---@return table[]
local function infoItems(book, owner)
    local sid = book.source_id
    local path = owner and owner.type == "book" and book.path or nil
    local name = path and path:match("[^/]+$")
    local format = book.format or (name and name:match("%.(%w+)$"))
    local size = tonumber(book.filesize) or (path and require("libs/libkoreader-lfs").attributes(path, "size"))
    local added = tonumber(book.inserted_at) or 0
    local items = {}
    for _idx, item in ipairs({
        { "source", sid == "zlib" and _("Z站") or sid == "opds" and _("OPDS")
            or sid and ((require("source.registry").meta(sid) or {}).name or sid) },
        { "article", format and format:upper() },
        { "hard_drive", size and size > 0 and require("util").getFriendlySize(size) },
        { "date_range", added > 0 and string.format(_("%s 加入"), os.date("%Y-%m-%d", added)) },
        { "category", book.category and (book.category:gsub("[,\n]+", " · ")) },
        { "collections_bookmark", book.series },
        { "folder", name },
    }) do
        if item[2] and item[2] ~= "" then items[#items + 1] = item end
    end
    return items
end

--- 一行排开，放不下的项连同其后各项整项隐藏。
---@param items table[]
---@param w number 物理像素
---@return table
local function infoStrip(items, w)
    local t = Theme.current()
    local color = Blitbuffer.Color8(t.color.muted)
    local gap = Theme.px(t.space.md)
    local row = HorizontalGroup:new{ align = "center" }
    local used = 0
    for _idx, item in ipairs(items) do
        local label = Icon.label{
            name = item[1], text = item[2], color = color,
            size = t.font.caption, font_size = t.font.caption, gap = Theme.px(t.space.xs),
        }
        local need = label:getSize().w + (#row > 0 and gap or 0)
        if used + need > w then break end
        if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = label
        used = used + need
    end
    return row
end

return function(Detail)
function Detail:buildHero(w, book, origin, can_read)
    local desc = Book.desc(book)
    return Hero.widget(self.plugin, Common.bookOwnerSource(book, self.source), book, {
        width = w, pad = 0,
        cover_width = math.floor(w * 0.24),
        title_lines = 3,
        on_tap = can_read and function() self:openBook() end or nil,
        on_info_tap = origin ~= "store" and desc ~= "" and function()
            TextViewer:new{ title = Book.title(book), text = desc }:show()
        end or nil,
        show_parent = self,
        show_progress = origin ~= "store",
        show_desc = origin ~= "store",
    })
end

--- 内容区：零碎信息行，下接书城简介（吃满剩余高度）或本机阅读统计。
---@param w number 物理像素
---@param avail_h number 内容区可用高度
---@return table
function Detail:buildContent(w, avail_h)
    local t = Theme.current()
    local gap = Theme.px(t.space.md)
    local info = VerticalGroup:new{ align = "left" }
    local strip = infoStrip(infoItems(self.book, Common.bookOwnerSource(self.book, self.source)), w)
    if #strip > 0 then info[1], info[2] = strip, VerticalSpan:new{ width = gap } end
    -- VerticalGroup:getSize 会缓存子控件偏移，量过高度的组不能再追加子控件
    local rest = avail_h - info:getSize().h
    local kids = VerticalGroup:new{ align = "left", info }
    if self.origin ~= "store" then
        kids[#kids + 1] = self:buildStatsArea(w, rest)
        return kids
    end
    local desc = Book.desc(self.book)
    if desc == "" then return kids end
    local title = Common.sectionTitle(_("简介"), w)
    local title_gap = Theme.px(t.space.xs)
    kids[#kids + 1] = title
    kids[#kids + 1] = VerticalSpan:new{ width = title_gap }
    kids[#kids + 1] = Text.box("body", desc, w, {
        color = t.color.muted,
        height = math.max(1, rest - title:getSize().h - title_gap),
    })
    return kids
end

--- 最近几天：日期 + 时长条 + 时长，放不下时分页。
---@param w number 物理像素
---@param avail_h number 可用高度
---@return table|nil
function Detail:buildRecent(w, avail_h)
    local daily = self._daily or {}
    if #daily == 0 then return nil end
    local t = Theme.current()
    local gap = Theme.px(t.space.sm)
    local header = Text.line("caption", _("最近几天"), { color = t.color.muted })
    local row_h = header:getSize().h + gap
    local pager_h = Theme.px(t.control.height)
    local function rowsFit(budget)
        return math.floor((budget - header:getSize().h) / row_h)
    end
    local per = rowsFit(avail_h)
    if per < 1 then return nil end
    if #daily > per then per = math.max(1, rowsFit(avail_h - pager_h)) end
    local pages = math.ceil(#daily / per)
    local page = math.max(1, math.min(self._daily_page or 1, pages))
    self._daily_page = page

    -- 条形按全部天数里最长的一天归一。
    local max_s = 0
    for _idx, r in ipairs(daily) do max_s = math.max(max_s, r.seconds) end
    local date_w, dur_w = Theme.px(52), Theme.px(72)
    local bar_w = math.max(1, w - date_w - dur_w - gap * 2)
    local kids = VerticalGroup:new{ align = "left", header }
    for i = (page - 1) * per + 1, math.min(#daily, page * per) do
        local r = daily[i]
        local _y, m, d = tostring(r.ymd):match("^(%d+)%-(%d+)%-(%d+)$")
        kids[#kids + 1] = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = date_w, h = row_h },
                Text.line("caption", m and (m .. "-" .. d) or tostring(r.ymd), { color = t.color.muted }),
            },
            HorizontalSpan:new{ width = gap },
            Progress:new{ width = bar_w, percent = max_s > 0 and r.seconds / max_s * 100 or 0 },
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = dur_w, h = row_h },
                Text.line("caption", Catalog.formatDuration(r.seconds)),
            },
        }
    end
    if pages > 1 then
        local function go(p)
            self._daily_page = p
            self:refresh()
        end
        kids[#kids + 1] = Pager.widget({
            width = w,
            page = page,
            pages = pages,
            on_prev = function() go(page - 1) end,
            on_next = function() go(page + 1) end,
        })
    end
    return kids
end

--- 按进度比例外推剩余时长，再按最近有记录的这段日历天数（没读的日子也算）摊出日均，推出读完日期。
---@param percent number 0..100
---@param total_seconds number 累计时长
---@param daily table[] StatsDB.dailyByBook（日期倒序）
---@return number|nil remaining 秒；没开始或已读完为 nil
---@return number|nil finish 读完日期的时间戳；没有近期记录为 nil
local function estimate(percent, total_seconds, daily)
    local fraction = percent / 100
    if fraction <= 0 or fraction >= 1 or total_seconds <= 0 then return nil end
    local remaining = math.floor(total_seconds * (1 - fraction) / fraction)
    local sum = 0
    for _idx, r in ipairs(daily) do sum = sum + r.seconds end
    if sum <= 0 then return remaining end
    local y, m, d = tostring(daily[#daily].ymd):match("^(%d+)%-(%d+)%-(%d+)$")
    if not y then return remaining end
    local today = os.date("*t")
    local now = os.time{ year = today.year, month = today.month, day = today.day, hour = 12 }
    local span = math.floor((now - os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
        / 86400 + 0.5) + 1
    return remaining, now + math.ceil(remaining / (sum / span)) * 86400
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

--- 阅读情况区：KPI 卡片两行三列 + 最近几天；无本机记录时单行占位。
---@param w number 物理像素
---@param avail_h number 可用高度
---@return table
function Detail:buildStatsArea(w, avail_h)
    local t = Theme.current()
    local st = self._stats
    if not st or st.pages <= 0 then
        return Text.line("body", _("暂无阅读记录"), { width = w, color = t.color.muted })
    end
    local gap = Theme.px(t.space.sm)
    ---@param ts number|nil
    ---@return string
    local function date(ts) return ts and ts > 0 and os.date("%Y-%m-%d", ts) --[[@as string]] or "—" end
    local remaining, finish = estimate(tonumber(self.book.percent) or 0, st.total_seconds, self._daily or {})
    local kpi = VerticalGroup:new{
        align = "left",
        kpiRow(w, gap, {
            { Catalog.formatDuration(st.total_seconds), _("累计时长") },
            { tostring(st.pages), _("已读页数") },
            { date(st.last_read), _("上次阅读") },
        }),
        VerticalSpan:new{ width = gap },
        kpiRow(w, gap, {
            { date(st.first_read), _("开始日期") },
            { remaining and Catalog.formatDuration(remaining) or "—", _("预计剩余") },
            { date(finish), _("预计读完") },
        }),
    }
    local kids = VerticalGroup:new{ align = "left", kpi }
    local recent = self:buildRecent(w, avail_h - kpi:getSize().h - gap * 2)
    if recent then
        kids[#kids + 1] = VerticalSpan:new{ width = gap * 2 }
        kids[#kids + 1] = recent
    end
    return kids
end
end
