--[[--
侧栏第 1 页：当前书的封面、进度、阅读统计与简介。

只读本地库（books 元数据 + reading_stats），不联网。

@module koplugin.book.ui.reader.sidebar.info
--]]

require("l10n").apply()

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfo = require("ui.components.bookinfo")
local Catalog = require("book.catalog")
local Common = require("ui.desktop.detail.common")
local StatsDB = require("db.stats")
local UI = require("ui.components.bookui")
local _ = require("gettext")

---@class BookSidebarInfo
local Info = {}

--- 展示用书籍行：库里元数据 + 会话实时进度；未入库时退回文档属性。
---@param snapshot ReaderSessionSnapshot
---@return table
local function displayBook(snapshot)
    local identity = snapshot.identity
    local book = {}
    for k, v in pairs(identity.book or {}) do book[k] = v end
    local props = snapshot.ui.doc_props or {}
    book.source_id, book.stable_id = identity.source_id, identity.stable_id
    book.title = book.title or props.display_title
    book.authors = book.authors or props.authors
    book.intro = book.intro or (props.description and require("util").htmlToPlainTextIfHtml(props.description))
    book.percent = snapshot.percent
    return book
end

---@param snapshot ReaderSessionSnapshot
---@param width number
---@param height number
---@param show_parent table 封面异步加载完成后重绘的窗口
---@return table
function Info.build(snapshot, width, height, show_parent)
    local identity = snapshot.identity
    local book = displayBook(snapshot)
    local Session = require("ui.reader.session")
    local hero, hero_h = BookInfo.hero(nil, identity.source, book, {
        width = width,
        pad = 0,
        subtitle = Session.chapterTitle(snapshot),
        show_desc = false,
        show_parent = show_parent,
    })

    local stats = StatsDB.summaryByBook(identity.source_id, identity.stable_id)
    local remaining = Session.remainingSeconds()
    local gap = UI.sz(10)
    local cell_w = math.floor((width - gap * 2) / 3)
    local kpi = HorizontalGroup:new{ align = "center" }
    local kpi_h = 0
    for i, item in ipairs({
        { Catalog.formatDuration(stats.total_seconds), _("累计时长") },
        { tostring(stats.pages), _("已读页数") },
        { remaining and Catalog.formatDuration(remaining) or "—", _("预计剩余") },
    }) do
        if i > 1 then kpi[#kpi + 1] = HorizontalSpan:new{ width = gap } end
        local card, card_h = Common.kpiCard(cell_w, item[1], item[2])
        kpi[#kpi + 1] = card
        kpi_h = math.max(kpi_h, card_h)
    end

    local title = Common.sectionTitle(_("简介"), width)
    local col = VerticalGroup:new{
        align = "left",
        hero,
        VerticalSpan:new{ width = gap },
        kpi,
        VerticalSpan:new{ width = gap },
        title,
    }
    local desc = BookInfo.desc(book)
    local desc_h = height - hero_h - kpi_h - gap * 2 - title:getSize().h
    if desc == "" then
        col[#col + 1] = UI.mutedText(_("暂无简介"), width, 13)
    elseif desc_h > UI.sz(20) then
        col[#col + 1] = TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 14),
            width = width,
            height = desc_h,
            alignment = "left",
            fgcolor = UI.muted(),
            height_overflow_show_ellipsis = true,
        }
    end
    return col
end

return Info
