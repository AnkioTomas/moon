--[[--
订阅页「文章流」纸质风格：跨订阅源的文章时间线，版式照杂志目录页。

  [全部 ⌄]                          [+] [⟳] [↓] [🗑]
  ─────────────────────────────────────────────
  未读文章                                  940
  未读  全部  收藏                      [🔍 搜索]
  ─────────────────────────────────────────────
  • 标题最多两行……………………………………………
    来源 · 分组 · 10-24
  ★ 已收藏的文章
    来源 · 10-24
  ─────────────────────────────────────────────
  [<]              第 1 / 20 页             [>]

左上角下拉选范围（全部 / 分组 / 单个源）；右上角依次是添加、刷新当前范围、缓存当前范围未读、订阅源管理。
点条目打开文章，点右侧星标收藏 / 取消收藏；已读条目标题淡灰、没有圆点。

@module koplugin.book.features.subscribe.paper
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local SubDB = require("features.subscribe.db")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Icon = require("ui.themes.widgets.icon")
local Button = require("ui.themes.widgets.button")
local Pager = require("ui.themes.widgets.pager")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local T = require("ffi/util").template
local _ = require("gettext")

local PAGE_MAX = 20
local MODES = {
    { id = "unread", label = function() return _("未读") end, title = function() return _("未读文章") end },
    { id = "all", label = function() return _("全部") end, title = function() return _("全部文章") end },
    { id = "star", label = function() return _("收藏") end, title = function() return _("收藏文章") end },
}

---@class BookSubscribePaper
local Paper = {}

---@param widget table
---@param on_tap fun()
---@return table
local function area(widget, on_tap)
    local size = widget:getSize()
    local box = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }, widget }
    local function range(ges) return GestureRange:new{ ges = ges, range = function() return box.dimen end } end
    box.ges_events = { TapPaper = { range("tap") } }
    function box:onTapPaper() on_tap() return true end
    return box
end

---@param width number
---@param thick number
---@param ink number|nil
---@return table
local function rule(width, thick, ink)
    return Box:new{
        width = width, height = thick, style = { bg = ink or Theme.current().color.ink }, keep_bg = true,
    }
end

---@param page BookSubscribePage
function Paper.search(page)
    require("ui.themes.widgets.input"):new{
        title = _("搜索"), fields = { { text = page.stream_q or "", hint = _("标题关键词") } },
        callback = function(value)
            page:filter({ stream_q = value:match("^%s*(.-)%s*$") })
        end,
    }:show()
end

---@param page BookSubscribePage
---@param w integer
---@param h integer
---@return table
function Paper.view(page, w, h)
    local t = Theme.current()
    local pad, sm = Theme.px(t.space.lg), Theme.px(t.space.sm)
    local iw = w - pad * 2
    local mode = MODES[1]
    for _idx, m in ipairs(MODES) do
        if m.id == page.stream_mode then mode = m end
    end
    local q = page.stream_q or ""
    local opts = page:spec()
    opts.mode = mode.id
    local ink, faint = t.color.ink, t.color.faint
    local big = Theme.face("cfont", math.floor(t.font.hero * 0.7))

    local function ico(name, color)
        return Icon.widget{ name = name, size = t.control.icon, color = Theme.color(color or ink) }
    end
    local function padded(widget) return HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, widget } end
    --- 左右两端对齐的一行。
    local function ends(left, right)
        local gap = math.max(0, iw - left:getSize().w - right:getSize().w)
        local line = HorizontalGroup:new{ align = "center", left, HorizontalSpan:new{ width = gap }, right }
        return padded(line)
    end

    -- 顶栏：范围下拉 ........ 添加 刷新 全部已读 缓存 管理
    local pick
    pick = Button:new{ text = page:scopeLabel(), icon = "arrow_drop_down", trailing = true, size = "small",
        callback = function() page:pickScope(pick.dimen) end }
    local function tool(name, fn) return Button:new{ icon = name, variant = "ghost", size = "small", callback = fn } end
    local tools = HorizontalGroup:new{ align = "center",
        tool("add", function() page:showAdd() end),
        tool("refresh", function() page:refresh(page:scopeFeeds(), false, true) end),
        tool("done_all", function() page:markAllRead() end),
        tool("download", function() page:cacheUnread() end),
        tool("delete", function() page:showManage() end) }
    local head = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = sm }, ends(pick, tools),
        VerticalSpan:new{ width = sm }, padded(rule(iw, math.max(1, Theme.px(2)))) }

    -- 大标题 + 总数
    local _first, total = SubDB.stream(opts, 1, 0)
    local status = page:status()
    local title = ends(Text.line("hero", q ~= "" and T(_("搜索：%1"), q) or mode.title(), { width = iw - math.floor(iw / 4), face = big }),
        Text.line("hero", tostring(total), { width = math.floor(iw / 4), face = big }))

    -- 筛选行：未读 全部 收藏 │ 搜索
    local tabs = HorizontalGroup:new{ align = "top" }
    for _idx, m in ipairs(MODES) do
        local active = m.id == mode.id
        local label = Text.line("body", m.label(), { bold = active, color = active and t.color.accent or faint })
        local cell = VerticalGroup:new{ align = "center", label, VerticalSpan:new{ width = sm },
            rule(label:getSize().w, active and math.max(2, Theme.px(2)) or 0, t.color.accent) }
        tabs[#tabs + 1] = area(HorizontalGroup:new{ cell, HorizontalSpan:new{ width = pad } }, function()
            page:filter({ stream_mode = m.id })
        end)
    end
    local search = area(HorizontalGroup:new{ align = "center", ico("search", q ~= "" and t.color.accent or faint),
        HorizontalSpan:new{ width = sm }, Text.line("body", _("搜索"), { color = q ~= "" and t.color.accent or faint }) },
        function() Paper.search(page) end)
    local filter = VerticalGroup:new{ align = "left", ends(tabs, search), padded(rule(iw, 1, t.color.faint)) }

    -- 文章行：固定高度（标题两行 + 来源行），分页数才稳定。
    local bullet_w = Text.line("title", "★"):getSize().w
    local star_w = Theme.px(56)
    local text_w = iw - bullet_w - sm - star_w
    local title_h = Text.box("body", "国\n国", text_w, { max_lines = 2, bold = true }):getSize().h
    local meta_h = Text.line("caption", "国", {}):getSize().h
    local row_h = title_h + meta_h + sm * 2 + Theme.px(t.space.xs)
    local avail = h - head:getSize().h - title:getSize().h - filter:getSize().h - Theme.px(t.control.height)
    local size = math.max(1, math.min(PAGE_MAX, math.floor(avail / row_h)))
    page.pages = math.max(1, math.ceil(total / size))
    page.page = math.max(1, math.min(page.page, page.pages))

    local list = VerticalGroup:new{ align = "left" }
    local items = SubDB.stream(opts, page.page, size)
    for _idx, item in ipairs(items) do
        local meta = { item.feed_title }
        if item.grp ~= "" then meta[#meta + 1] = item.grp end
        if item.time > 0 then meta[#meta + 1] = os.date("%m-%d", item.time) end
        local mark = item.read and "" or "•"
        local body = VerticalGroup:new{ align = "left",
            Text.box("body", item.title, text_w, { max_lines = 2, bold = not item.read,
                color = item.read and faint or t.color.accent }),
            VerticalSpan:new{ width = Theme.px(t.space.xs) },
            Text.line("caption", table.concat(meta, " · "), { width = text_w, color = faint }) }
        local mark_widget = Text.line("title", mark ~= "" and mark or " ")
        local content = HorizontalGroup:new{ align = "top",
            mark_widget, HorizontalSpan:new{ width = bullet_w - mark_widget:getSize().w + sm }, body }
        local function toggleStar()
            SubDB.setStarred(item.feed_id, item.guid, not item.starred)
            require("ui.themes.widgets.toast"):new{ text = item.starred and _("已取消收藏") or _("已收藏"), timeout = 2 }:show()
            page:redraw()
        end
        local body_h = row_h - 1
        local cell = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = sm }, content,
            VerticalSpan:new{ width = math.max(0, body_h - sm - content:getSize().h) } }
        -- 图标字体只有描边星；已收藏用实心 ★ 字符，大小对齐图标
        local star_glyph = item.starred and Text.line("title", "★", { color = t.color.accent }) or ico("star", faint)
        local star = area(CenterContainer:new{ dimen = Geom:new{ w = star_w, h = body_h }, star_glyph }, toggleStar)
        list[#list + 1] = padded(VerticalGroup:new{ align = "left",
            HorizontalGroup:new{ area(cell, function() page:openItem(item) end), star },
            rule(iw, 1, t.color.faint) })
    end
    if #items == 0 then
        local empty = status or (q ~= "" and _("没有匹配的文章") or (mode.id == "star" and _("还没有收藏，点文章右侧的星标可收藏")
            or mode.id == "unread" and _("没有未读文章") or _("暂无文章")))
        list[1] = padded(VerticalGroup:new{ VerticalSpan:new{ width = pad },
            Text.box("body", empty, iw, { color = faint }) })
    end

    local group_all = VerticalGroup:new{ align = "left", head, title, filter, list,
        VerticalSpan:new{ width = math.max(0, avail - list:getSize().h) } }
    group_all[#group_all + 1] = Pager.widget({
        width = w, page = page.page, pages = page.pages, title = T(_("第 %1 / %2 页"), page.page, page.pages),
        keys = false,
        on_page = function(target) page:gotoPage(target) end,
    })
    return group_all
end

return Paper
