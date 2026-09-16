--[[-- 书籍详情子模块。 @module ui.desktop.detail --]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Catalog = require("book.catalog")
local BookInfo = require("ui.components.bookinfo")
local PageStrip = require("ui.components.pagestrip")
local UI = require("ui.components.bookui")
local _ = require("gettext")


local Common = require("ui.desktop.detail.common")
local sectionTitle = Common.sectionTitle
local kpiCard = Common.kpiCard

return function(Detail)
function Detail:buildHero(w, book, origin, can_read)
    local category = book.category
    if type(category) == "string" and category ~= "" then category = category:gsub("[,\n]+", " · ") else category = nil end
    local parts = {}
    if category then parts[#parts + 1] = category end
    if type(book.series) == "string" and book.series ~= "" then parts[#parts + 1] = book.series end
    return BookInfo.hero(self.plugin, self.source, book, {
        width = w, pad = 0,
        subtitle = #parts > 0 and table.concat(parts, " · ") or nil,
        on_tap = can_read and function() self:openBook() end or nil,
        show_parent = self,
        show_progress = origin ~= "store",
        show_desc = origin ~= "store",
    })
end

--- 内容区域：书城显示简介，图书馆显示阅读统计。
function Detail:buildContent(w, avail_h, origin, hero_h)
    if origin == "store" then
        local desc = BookInfo.desc(self.book or {})
        if desc == "" then return nil, 0 end
        local gap = UI.sz(12)
        local body = VerticalGroup:new{ align = "left",
            sectionTitle(_("简介"), w), VerticalSpan:new{ width = UI.sz(6) },
            TextBoxWidget:new{ text = desc, face = UI.face("xx_smallinfofont", 14), width = w,
                height = math.max(UI.sz(40), avail_h - hero_h - gap - UI.sz(30)), alignment = "left", fgcolor = UI.muted() }, }
        return body, body:getSize().h
    end
    local body = self:buildStatsArea(w, avail_h - hero_h - UI.sz(12))
    return body, body:getSize().h
end

function Detail:buildRecent(w, avail_h)
    local daily = self._daily or {}
    if #daily == 0 then
        return nil, 0
    end
    local row_h = UI.sz(22)
    local row_gap = UI.sz(8)
    local header = TextWidget:new{
        text = _("最近几天"),
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = UI.muted(),
    }
    local fixed_h = header:getSize().h + row_gap
    local pager_h = PageStrip.bandH()

    --- 预算内能放的行数。
    ---@param budget number 可用高度
    ---@return number
    local function rowsFit(budget)
        return math.floor((budget - fixed_h) / (row_h + row_gap))
    end

    local per = rowsFit(avail_h)
    if per < 1 then
        return nil, 0
    end
    local show_pager = #daily > per
    if show_pager then
        per = math.max(1, rowsFit(avail_h - pager_h))
    end
    per = math.min(per, #daily)
    local page, pages = PageStrip.clamp(self._daily_page, math.ceil(#daily / per))
    self._daily_page = page

    -- 条形按全部天数里最大当天时长归一
    local max_s = 0
    for _, r in ipairs(daily) do
        if r.seconds > max_s then max_s = r.seconds end
    end
    local date_w = UI.sz(52)
    local dur_w = UI.sz(64)
    local bar_w = math.max(1, w - date_w - dur_w - row_gap * 2)
    local kids = VerticalGroup:new{ align = "left", header }
    for i = (page - 1) * per + 1, math.min(#daily, page * per) do
        local r = daily[i]
        local _y, m, d = tostring(r.ymd):match("^(%d+)%-(%d+)%-(%d+)$")
        table.insert(kids, VerticalSpan:new{ width = row_gap })
        table.insert(kids, HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = date_w, h = row_h },
                TextWidget:new{
                    text = (m and d) and (m .. "-" .. d) or tostring(r.ymd),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = UI.muted(),
                },
            },
            HorizontalSpan:new{ width = row_gap },
            UI.progressBar(bar_w, UI.sz(6), max_s > 0 and (r.seconds / max_s * 100) or 0),
            HorizontalSpan:new{ width = row_gap },
            LeftContainer:new{
                dimen = Geom:new{ w = dur_w, h = row_h },
                TextWidget:new{
                    text = Catalog.formatDuration(r.seconds),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            },
        })
    end

    local used = kids:getSize().h
    if show_pager then
        --- 翻页：改页码重建。
        ---@param p number 目标页码
        ---@return nil
        local function goto2(p)
            self._daily_page = p
            self:updateView()
            require("ui/uimanager"):setDirty(self, "ui")
        end
        local pager = PageStrip.widget{
            width = w,
            page = page,
            pages = pages,
            on_prev = function() goto2(page - 1) end,
            on_next = function() goto2(page + 1) end,
        }
        table.insert(kids, pager)
        used = used + pager:getSize().h
    end
    return kids, used
end

--- 阅读情况区：KPI 卡片三列 + 最近几天（平铺分页）；无本机记录时单行占位。
---@param w number 可用宽度，单位像素
---@param avail_h number 可用高度，单位像素
---@return table
function Detail:buildStatsArea(w, avail_h)
    local st = self._stats
    if not st or st.pages <= 0 then
        return TextWidget:new{
            text = _("暂无阅读记录"),
            face = UI.face("xx_smallinfofont", 13),
            max_width = w,
            fgcolor = UI.muted(),
        }
    end

    local gap = UI.sz(10)
    local items = {
        { Catalog.formatDuration(st.total_seconds), _("累计时长") },
        { tostring(st.pages), _("已读页数") },
        { st.last_read > 0 and os.date("%Y-%m-%d", st.last_read) or "—", _("上次阅读") },
    }
    local cell_w = math.floor((w - gap * 2) / 3)
    local kpi_row = HorizontalGroup:new{ align = "center" }
    local kpi_h = 0
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(kpi_row, HorizontalSpan:new{ width = gap })
        end
        local card, card_h = kpiCard(cell_w, item[1], item[2])
        kpi_h = math.max(kpi_h, card_h)
        table.insert(kpi_row, card)
    end
    local kids = VerticalGroup:new{ align = "left", kpi_row }

    local recent, _recent_h = self:buildRecent(w, avail_h - kpi_h - gap)
    if recent then
        table.insert(kids, VerticalSpan:new{ width = gap })
        table.insert(kids, recent)
    end
    return kids
end


end
