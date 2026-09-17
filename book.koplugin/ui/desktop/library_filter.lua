--[[--
Kindle 风格图书馆筛选：底栏全宽面板、网状遮罩、同屏分组、组内左右翻页。
@module koplugin.book.ui.desktop.library_filter
--]]
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local BookInfo = require("ui.components.bookinfo")
local MeshMask = require("ui.components.meshmask")
local PageContainer = require("ui.components.pagecontainer")
local Surface = require("ui.components.surface")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local T = require("ffi/util").template

local Filter = {}
local FLAG = { category = "uncategorized", series = "unseries" }

local function copy(src)
    local out = {}
    for k, v in pairs(src or {}) do out[k] = v end
    return out
end

local function selected(d, kind, value)
    local flag = FLAG[kind]
    if flag and value == "" then return not not d[flag] end
    return d[kind] == value
end

local function choose(d, kind, value)
    if kind == "sort" then d.sort = value; return end
    local flag = FLAG[kind]
    if selected(d, kind, value) then
        d[kind] = nil
        if flag then d[flag] = nil end
    elseif flag then
        d[kind], d[flag] = value ~= "" and value or nil, value == "" or nil
    else
        d[kind] = value
    end
end

local function values(rows, key, empty_label)
    local out = {}
    for _, item in ipairs(rows or {}) do
        local v = item[key] or ""
        out[#out + 1] = { value = v, text = v ~= "" and v or empty_label, count = tonumber(item.count) or 0 }
    end
    return out
end

local function pill(item, checked, max_w, cb)
    local pad = UI.sz(10)
    local label = TextWidget:new{
        text = item.count ~= nil and T(_("%1（%2）"), item.text, item.count) or item.text,
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = checked and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        max_width = math.max(1, max_w - pad * 2),
        truncate_with_ellipsis = true,
    }
    local w = math.min(max_w, label:getSize().w + pad * 2)
    local tap = BookInfo.tappable(w, UI.sz(36), cb)
    tap[1] = Surface.build{ child = label, options = {
        width = w, height = UI.sz(36), padding = UI.sz(4), shadow = false,
        background = checked and Blitbuffer.COLOR_BLACK or UI.surface(),
    }, kind = "pill" }
    return tap, w
end

local function packPages(group, width, draft, on_pick)
    local pages, rows, row, used, gap = {}, {}, HorizontalGroup:new{}, 0, UI.sz(6)
    local function flushRow()
        if #row > 0 then rows[#rows + 1] = row end
        row, used = HorizontalGroup:new{}, 0
        if #rows == 2 then pages[#pages + 1], rows = rows, {} end
    end
    for _, item in ipairs(group.values) do
        local wgt, w = pill(item, selected(draft, group.kind, item.value), width, function()
            choose(draft, group.kind, item.value)
            on_pick()
        end)
        if #row > 0 and used + gap + w > width then flushRow() end
        if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap }; used = used + gap end
        row[#row + 1], used = wgt, used + w
    end
    flushRow()
    if #rows > 0 then pages[#pages + 1] = rows end
    if #pages == 0 then pages[1] = {} end
    return pages
end

local function groupWidget(group, width, draft, page, set_page, on_pick)
    local pages = packPages(group, width, draft, on_pick)
    if #pages > 1 then
        pages = packPages(group, PageContainer.contentWidth(width, #pages), draft, on_pick)
    end
    page = math.max(1, math.min(page or 1, #pages))
    local gap = UI.sz(6)
    local rows = VerticalGroup:new{ align = "left" }
    for i, r in ipairs(pages[page]) do
        if i > 1 then rows[#rows + 1] = VerticalSpan:new{ width = gap } end
        rows[#rows + 1] = r
    end
    local content = PageContainer.wrap{
        child = rows,
        width = width,
        page = page,
        pages = #pages,
        on_prev = function() set_page(page - 1) end,
        on_next = function() set_page(page + 1) end,
    }
    return VerticalGroup:new{ align = "left",
        TextWidget:new{ text = group.title, face = UI.face("xx_smallinfofont", 14), bold = true },
        VerticalSpan:new{ width = gap },
        content,
    }
end

---@param opts { data: table, current: table, sort: string, on_apply: fun(filter: table, sort: string) }
function Filter.open(opts)
    local data, draft = opts.data or {}, copy(opts.current)
    draft.sort = opts.sort or "recent_added"
    local page = { source_id = 1, category = 1, series = 1, read_status = 1, sort = 1 }
    local dialog
    local status = {
        { value = "new", text = _("新书"), count = 0 },
        { value = "read", text = _("已读"), count = 0 },
        { value = "unread", text = _("未读"), count = 0 },
    }
    for _, row in ipairs(data.read_counts or {}) do
        for _, item in ipairs(status) do
            if item.value == row.status then item.count = tonumber(row.count) or 0 end
        end
    end
    local groups = {}
    -- 混合模式才有 source_counts；单源不显示源组。
    if data.source_counts and #data.source_counts > 0 then
        local src = {}
        for _, row in ipairs(data.source_counts) do
            local id = row.source_id or ""
            if id ~= "" then
                src[#src + 1] = {
                    value = id,
                    text = (type(row.name) == "string" and row.name ~= "" and row.name) or id,
                    count = tonumber(row.count) or 0,
                }
            end
        end
        if #src > 0 then
            groups[#groups + 1] = { kind = "source_id", title = _("数据源"), values = src }
        end
    end
    groups[#groups + 1] = { kind = "category", title = _("分类"), values = values(data.category_counts, "category", _("未分类")) }
    groups[#groups + 1] = { kind = "series", title = _("系列"), values = values(data.series_counts, "series", _("无系列")) }
    groups[#groups + 1] = { kind = "read_status", title = _("阅读状态"), values = status }
    groups[#groups + 1] = { kind = "sort", title = _("排序"), values = {
        { value = "recent_added", text = _("最近添加") },
        { value = "recent_read", text = _("最近阅读") },
        { value = "title", text = _("书名") },
        { value = "author", text = _("作者") },
    } }
    local function apply()
        local filter = copy(draft)
        local sort = filter.sort or "recent_added"
        filter.sort = nil
        opts.on_apply(filter, sort)
    end
    local function close()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function render()
        close()
        local screen = Device.screen:getSize()
        local pad = UI.sz(16)
        local width = screen.w
        local inner = math.max(1, width - pad * 2)
        local edge = math.max(UI.sz(3), UI.line() * 3)
        local clear_label = TextWidget:new{
            text = _("全部清除"),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
        }
        local clear_size = clear_label:getSize()
        local clear = BookInfo.tappable(clear_size.w, math.max(clear_size.h, UI.sz(28)), function()
            draft = { search = draft.search, sort = "recent_added" }
            apply()
            render()
        end)
        clear[1] = clear_label
        local title_text = TextWidget:new{ text = _("筛选"), face = UI.face("xx_smallinfofont", 16), bold = true }
        local title_h = math.max(title_text:getSize().h, clear:getSize().h)
        local title_row = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = title_h },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = title_h }, title_text },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = title_h }, clear },
        }
        local body = VerticalGroup:new{ align = "left",
            title_row,
            VerticalSpan:new{ width = UI.sz(8) },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = UI.line() }, background = UI.rule() },
            VerticalSpan:new{ width = UI.sz(12) },
        }
        for i, group in ipairs(groups) do
            if i > 1 then body[#body + 1] = VerticalSpan:new{ width = UI.sz(12) } end
            body[#body + 1] = groupWidget(group, inner, draft, page[group.kind], function(v)
                page[group.kind] = v
                render()
            end, function() apply(); render() end)
        end
        local panel = VerticalGroup:new{
            LineWidget:new{ dimen = Geom:new{ w = width, h = edge }, background = Blitbuffer.COLOR_BLACK },
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                width = width,
                body,
            },
        }
        local mesh = MeshMask.widget{ width = screen.w, height = screen.h }
        dialog = InputContainer:new{ dimen = screen }
        dialog[1] = OverlapGroup:new{
            allow_mirroring = false,
            dimen = Geom:new{ w = screen.w, h = screen.h },
            mesh,
            BottomContainer:new{ dimen = screen, panel },
        }
        dialog.ges_events = {
            TapFilterClose = {
                GestureRange:new{ ges = "tap", range = function() return dialog.dimen end },
            },
        }
        -- InputContainer 手势：Event(name, args, ev) → onXxx(self, args, ev)
        -- 面板是贴底 VerticalGroup，不保证 dimen；用高度判断点是否落在底栏。
        local panel_h = panel:getSize().h
        dialog.onTapFilterClose = function(_, _arg, ges)
            if ges and ges.pos and ges.pos.y >= screen.h - panel_h then return true end
            close()
            return true
        end
        if Device:hasKeys() then
            dialog.key_events = { Close = { { Device.input.group.Back } } }
            dialog.onClose = function() close(); return true end
        end
        UIManager:show(dialog)
    end
    render()
    return dialog
end

return Filter
