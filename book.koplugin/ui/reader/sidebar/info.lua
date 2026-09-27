--[[--
侧栏第 1 页：当前书的封面、进度、阅读统计与简介；右上角关闭按钮退出本书。

只读本地库（books 元数据 + reading_stats），不联网。

@module koplugin.book.ui.reader.sidebar.info
--]]

require("l10n").apply()

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfo = require("ui.components.bookinfo")
local Catalog = require("book.catalog")
local Common = require("ui.desktop.detail.common")
local Icon = require("ui.components.icon")
local StatsDB = require("db.stats")
local UI = require("ui.components.bookui")
local _ = require("gettext")

---@class BookSidebarInfo
local Info = {}

--- 展示用书籍行：库里元数据 + 会话实时进度；未入库时退回文档属性。
---@param snapshot ReaderSessionSnapshot
---@return table
function Info.book(snapshot)
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

--- 右上角关闭（退出本书）按钮。
---@param size number
---@param on_exit fun()
---@return table
local function exitButton(size, on_exit)
    local tap = InputContainer:new{ dimen = Geom:new{ w = size, h = size } }
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        Icon.widget{ name = "close", size = 22 },
    }
    tap.ges_events = {
        TapSidebarExit = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapSidebarExit = function()
        on_exit()
        return true
    end
    return tap
end

---@param snapshot ReaderSessionSnapshot
---@param width number
---@param height number
---@param show_parent table 封面异步加载完成后重绘的窗口
---@param on_exit fun() 点关闭按钮：退出本书
---@return table
function Info.build(snapshot, width, height, show_parent, on_exit)
    local identity = snapshot.identity
    local book = Info.book(snapshot)
    local Session = require("ui.reader.session")
    local exit_w = UI.sz(40)
    local hero, hero_h = BookInfo.hero(nil, identity.source, book, {
        width = width - exit_w,
        pad = 0,
        subtitle = Session.chapterTitle(snapshot),
        show_desc = false,
        show_parent = show_parent,
    })
    local top = HorizontalGroup:new{ align = "top", hero, exitButton(exit_w, on_exit) }

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
        top,
        VerticalSpan:new{ width = gap },
        kpi,
        VerticalSpan:new{ width = gap },
        title,
    }
    local desc = BookInfo.desc(book)
    local desc_h = height - math.max(hero_h, exit_w) - kpi_h - gap * 2 - title:getSize().h
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
