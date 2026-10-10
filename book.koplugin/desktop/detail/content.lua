--[[-- 书籍详情：Hero 与内容区（书城简介 / 本机阅读统计）。 @module desktop.detail --]]

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
local Pager = require("ui.themes.widgets.pager")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

local Common = require("desktop.detail.common")

return function(Detail)
function Detail:buildHero(w, book, origin, can_read)
    local category = book.category
    if category and category ~= "" then category = category:gsub("[,\n]+", " · ") else category = nil end
    local parts = {}
    local sid = book.source_id
    if sid then
        local name = sid == "zlib" and _("Z站")
            or sid == "opds" and _("OPDS")
            or (require("source.registry").meta(sid) or {}).name
            or sid
        parts[#parts + 1] = name
    end
    if category then parts[#parts + 1] = category end
    if book.series and book.series ~= "" then parts[#parts + 1] = book.series end
    return Hero.widget(self.plugin, Common.bookOwnerSource(book, self.source), book, {
        width = w, pad = 0,
        subtitle = #parts > 0 and table.concat(parts, " · ") or nil,
        on_tap = can_read and function() self:openBook() end or nil,
        show_parent = self,
        show_progress = origin ~= "store",
        show_desc = origin ~= "store",
    })
end

--- 内容区：书城显示简介，图书馆显示阅读统计。
---@param w number 物理像素
---@param avail_h number 内容区可用高度
---@return table|nil
function Detail:buildContent(w, avail_h)
    if self.origin ~= "store" then return self:buildStatsArea(w, avail_h) end
    local desc = Book.desc(self.book)
    if desc == "" then return nil end
    local t = Theme.current()
    local title = Common.sectionTitle(_("简介"), w)
    local gap = Theme.px(t.space.xs)
    return VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{ width = gap },
        Text.box("body", desc, w, {
            color = t.color.muted,
            height = math.max(1, avail_h - title:getSize().h - gap),
        }),
    }
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

--- 阅读情况区：KPI 卡片三列 + 最近几天；无本机记录时单行占位。
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
    local cell_w = math.floor((w - gap * 2) / 3)
    local kpi = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs({
        { Catalog.formatDuration(st.total_seconds), _("累计时长") },
        { tostring(st.pages), _("已读页数") },
        { st.last_read > 0 and os.date("%Y-%m-%d", st.last_read) or "—", _("上次阅读") },
    }) do
        if i > 1 then kpi[#kpi + 1] = HorizontalSpan:new{ width = gap } end
        kpi[#kpi + 1] = Common.kpiCard(cell_w, item[1], item[2])
    end
    local kids = VerticalGroup:new{ align = "left", kpi }
    local recent = self:buildRecent(w, avail_h - kpi:getSize().h - gap * 2)
    if recent then
        kids[#kids + 1] = VerticalSpan:new{ width = gap * 2 }
        kids[#kids + 1] = recent
    end
    return kids
end
end
