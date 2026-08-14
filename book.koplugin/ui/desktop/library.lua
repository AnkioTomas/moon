--[[--
图书馆：封面优先书架（封面+进度角标+单行书名；尺度参考主页）
  顶栏：搜索 / 筛选 / 清除 + 右上角总数
  筛选互斥：同一时刻只应用一个条件（搜索或分类/标签/系列/作者之一）

筛选字段与 /index/book/filters 对齐：
  favorites  → 分类（list 参数 favorite）
  categories → 标签（list 参数 category）
  groupNames → 系列（list 参数 series）
  authors    → 作者（list 参数 author）

@module koplugin.book.ui.library
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local Pager = require("ui.components.pager")
local Popup = require("ui.components.popup")
local Store = require("book.store")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Library = {}

local FILTER_KINDS = {
    favorite = {
        title = _("选择分类"),
        label = _("分类"),
        list_key = "favorites",
        query_key = "favorite",
        aliases = { "favorites" },
    },
    category = {
        title = _("选择标签"),
        label = _("标签"),
        list_key = "categories",
        query_key = "category",
        aliases = { "categories", "tags" },
    },
    series = {
        title = _("选择系列"),
        label = _("系列"),
        list_key = "groupNames",
        query_key = "series",
        aliases = { "groupNames", "series" },
    },
    author = {
        title = _("选择作者"),
        label = _("作者"),
        list_key = "authors",
        query_key = "author",
        aliases = { "authors", "author" },
    },
}

local FILTER_ORDER = { "favorite", "category", "series", "author" }

--- 顶栏入口：图标 + 文字，无边框。
---@param icon_name string
---@param text string
---@param callback fun()|nil
---@return table
local function iconAction(icon_name, text, callback)
    local content = Icon.label{
        name = icon_name,
        text = text,
        size = 18,
        font_size = 15,
        gap = UI.sz(4),
    }
    local pad_x = UI.sz(8)
    local pad_y = UI.sz(6)
    local cs = content:getSize()
    local tw = pad_x * 2 + cs.w
    local th = math.max(UI.sz(32), cs.h) + pad_y * 2
    local tap = BookInfo.tappable(tw, th, callback)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = tw, h = th },
        content,
    }
    return tap
end

--- 从 filters 响应里按定义取列表（含别名回退）。
---@param data table|nil
---@param def table|nil
---@return table
local function pickFilterList(data, def)
    if type(data) ~= "table" or not def then return {} end
    local list = data[def.list_key]
    if type(list) == "table" and #list > 0 then
        return list
    end
    for _, alt in ipairs(def.aliases or {}) do
        local alt_list = data[alt]
        if type(alt_list) == "table" and #alt_list > 0 then
            return alt_list
        end
    end
    return type(list) == "table" and list or {}
end

--- 筛选互斥：同一时刻只保留一个条件（含 search）。
---@param desktop table
---@param key string|nil
---@param value string|nil
function Library.applyExclusive(desktop, key, value)
    desktop.filter = {}
    if key and value and value ~= "" then
        desktop.filter[key] = value
    end
    desktop.page = 1
    desktop._library_state = nil
    desktop.tab = "library"
    desktop:rebuild()
end

--- 封面 + 单行书名。
---@param ctx table
---@param book table
---@param slot_w number
---@param cw number
---@param ch number
---@param on_open fun(book: table)|nil
---@return table, number
local function coverCell(ctx, book, slot_w, cw, ch, on_open)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = true,
        show_parent = ctx.desktop,
    }))
    local title_gap = UI.sz(4)
    local title_h = UI.sz(22)
    local total_h = ch + title_gap + title_h
    local tap = BookInfo.tappable(slot_w, total_h, function()
        if on_open then on_open(book) end
    end)
    tap[1] = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = ch },
            cover,
        },
        VerticalSpan:new{ width = title_gap },
        TextWidget:new{
            text = BookInfo.title(book),
            face = UI.face("xx_smallinfofont", 13),
            max_width = slot_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap, total_h
end

--- 按内容区尺寸算出网格容量；请求 page_size 必须与此一致。
---@param w number
---@param h number
---@return table
function Library.gridMetrics(w, h)
    w = math.max(1, tonumber(w) or 1)
    h = math.max(1, tonumber(h) or 1)
    local pad = UI.sz(10)
    local top_h = UI.sz(52)
    local bottom_h = Pager.bandH()
    local grid_h = math.max(1, h - top_h - bottom_h)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, gap, row_gap, cell_h = UI.denseCoverMetrics(avail, grid_h, {
        title_extra = UI.sz(4) + UI.sz(22),
    })
    local rows = math.max(1, math.floor((grid_h + row_gap) / (cell_h + row_gap)))
    return {
        pad = pad,
        top_h = top_h,
        bottom_h = bottom_h,
        grid_h = grid_h,
        gap = gap,
        row_gap = row_gap,
        cols = cols,
        rows = rows,
        slot_w = slot_w,
        cw = cw,
        ch = ch,
        cell_h = cell_h,
        page_size = cols * rows,
    }
end

--- 按网格度量铺满一页封面格子。
---@param ctx table
---@param books table
---@param m table
---@param on_open fun(book: table)|nil
---@return table, number
local function buildGrid(ctx, books, m, on_open)
    local pad, gap, row_gap = m.pad, m.gap, m.row_gap
    local cols, slot_w, cw, ch = m.cols, m.slot_w, m.cw, m.ch
    local cell_h = m.cell_h
    local grid_h = m.grid_h

    local grid = VerticalGroup:new{ align = "left" }
    local row_group = HorizontalGroup:new{}
    local col_i = 0
    local row_n = 0
    local grid_used = 0

    --- 冲刷当前行进网格。
    local function flushRow()
        if row_n > 0 then
            table.insert(grid, VerticalSpan:new{ width = row_gap })
            grid_used = grid_used + row_gap
        end
        table.insert(grid, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad,
            padding_right = pad,
            margin = 0,
            row_group,
        })
        grid_used = grid_used + cell_h
        row_group = HorizontalGroup:new{}
        col_i = 0
        row_n = row_n + 1
    end

    for _, book in ipairs(books) do
        if col_i == 0 and grid_used + cell_h > grid_h then
            break
        end
        local cell = coverCell(ctx, book, slot_w, cw, ch, on_open)
        if col_i > 0 then
            table.insert(row_group, HorizontalSpan:new{ width = gap })
        end
        table.insert(row_group, cell)
        col_i = col_i + 1
        if col_i >= cols then
            flushRow()
        end
    end
    if col_i > 0 and grid_used + cell_h <= grid_h then
        flushRow()
    end
    return grid, grid_used
end

--- 构建图书馆页 UI（工具栏 + 网格 + 分页）。
---@param ctx table
---@param state table
---@param opts table|nil
---@return table
function Library.build(ctx, state, opts)
    opts = opts or {}
    local w = ctx.width
    local h = ctx.height
    local m = Library.gridMetrics(w, h)
    local pad = m.pad
    local page = opts.page or 1
    local pages = opts.pages or 1
    local total = opts.total or 0
    local books = state.books
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end

    local tools_kids = { align = "center" }
    local caps = (ctx.source and ctx.source.capabilities and ctx.source:capabilities()) or {}
    local has_tool = false
    if caps.search then
        table.insert(tools_kids, iconAction("search", _("搜索"), function()
            if ctx.desktop then Library.showSearch(ctx.desktop) end
        end))
        has_tool = true
    end
    if caps.filters then
        if has_tool then
            table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
        end
        table.insert(tools_kids, iconAction("filter_list", _("筛选"), function()
            if ctx.desktop then Library.showFilterRoot(ctx.desktop) end
        end))
        has_tool = true
    end
    if has_tool then
        table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
        table.insert(tools_kids, iconAction("clear", _("清除"), function()
            if ctx.desktop then Library.clearFilters(ctx.desktop) end
        end))
    end
    local tools = HorizontalGroup:new(tools_kids)
    local total_label = TextWidget:new{
        text = T(_("共%1"), total),
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    }
    local mid = math.max(UI.sz(8), (w - pad * 2) - tools:getSize().w - total_label:getSize().w)

    local top = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        padding_bottom = UI.sz(4),
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = m.top_h },
        HorizontalGroup:new{
            align = "center",
            tools,
            HorizontalSpan:new{ width = mid },
            total_label,
        },
    }

    local handlers = {
        on_prev = opts.on_prev,
        on_next = opts.on_next,
        on_first = opts.on_first,
        on_last = opts.on_last,
    }

    local kids = { align = "left", top }
    local used = m.top_h
    local band_h = m.bottom_h

    --- 空态/加载占位。
    ---@param msg string
    local function placeholder(msg)
        local ph = math.max(1, h - band_h - used)
        table.insert(kids, CenterContainer:new{
            dimen = Geom:new{ w = w, h = ph },
            TextWidget:new{
                text = msg,
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = UI.muted(),
            },
        })
        used = used + ph
    end

    if not books then
        placeholder(opts.loading_text or _("加载中…"))
    elseif #books == 0 then
        placeholder(state.err or opts.empty_text or _("没有书籍"))
    else
        local grid, grid_h = buildGrid(ctx, books, m, on_open)
        table.insert(kids, grid)
        used = used + grid_h
    end

    local filler = math.max(0, h - band_h - used)
    if filler > 0 then
        table.insert(kids, VerticalSpan:new{ width = filler })
    end
    table.insert(kids, Pager.band(w, page, pages, handlers))

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(kids),
    }
end

--- 异步拉取图书馆列表。
---@param desktop table
function Library.fetch(desktop)
    --- 写入图书馆状态并重建。
    ---@param books table|nil
    ---@param err string|nil
    local function done(books, err)
        if desktop._closed or desktop.tab ~= "library" then
            return
        end
        desktop._library_state = {
            books = books or {},
            err = err,
        }
        desktop:rebuild()
    end

    if desktop._library_fetch_cancel then
        desktop._library_fetch_cancel:cancel()
        desktop._library_fetch_cancel = nil
    end

    Library.syncPageSize(desktop)
    local source = desktop.source
    local generation = desktop.source_generation or 0
    local page = desktop.page or 1
    local page_size = desktop.page_size or 1
    local f = desktop.filter or {}
    local search = f.search or ""
    local favorite = f.favorite or ""
    local category = f.category or ""
    local series = f.series or ""
    local author = f.author or ""
    local finished = f.finished or ""

    if not source or not source.configured or not source:configured() then
        done({}, _("请先在设置里配置当前数据源"))
        return
    end
    if not source.listLibraryAsync then
        done({}, _("当前数据源不支持书库"))
        return
    end
    desktop._library_fetch_cancel = source:listLibraryAsync({
        page = page,
        page_size = page_size,
        search = search,
        favorite = favorite,
        category = category,
        series = series,
        author = author,
        finished = finished,
    }, function(res, err)
        if desktop._closed or desktop.tab ~= "library"
            or desktop.source ~= source or (desktop.source_generation or 0) ~= generation then
            return
        end
        desktop._library_fetch_cancel = nil
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        desktop.total = tonumber(res.count) or 0
        local books = res.data or {}
        Store.rememberMany(books)
        done(books)
    end)
end

--- 弹出筛选根菜单（分类/标签/系列/作者）。
---@param desktop table
function Library.showFilterRoot(desktop)
    local items = {}
    for _, kind in ipairs(FILTER_ORDER) do
        local def = FILTER_KINDS[kind]
        local k = kind
        table.insert(items, {
            text = def.label,
            callback = function()
                Library.showFilterPicker(desktop, k)
            end,
        })
    end

    desktop._filter_root = Popup.list{
        title = _("筛选"),
        items = items,
        close_callback = function()
            desktop._filter_root = nil
        end,
    }
end

--- 弹出某一类筛选值选择器。
---@param desktop table
---@param kind string
function Library.showFilterPicker(desktop, kind)
    local def = FILTER_KINDS[kind]
    if not def then
        logger.warn("book unknown filter kind", kind)
        return
    end
    local title = def.title
    local query_key = def.query_key

    --- 用筛选名列表刷新菜单项。
    ---@param names table|nil
    local function applyList(names)
        local items = {{
            text = _("全部"),
            callback = function()
                Library.applyExclusive(desktop, query_key, "")
            end,
        }}
        for _, name in ipairs(names or {}) do
            local n = tostring(name)
            table.insert(items, {
                text = n,
                callback = function()
                    Library.applyExclusive(desktop, query_key, n)
                end,
            })
        end
        if #(names or {}) == 0 then
            table.insert(items, { text = _("（暂无）"), enabled = false })
        end
        Popup.setListItems(desktop._filter_menu, title, items)
    end

    desktop._filter_menu = Popup.list{
        title = title,
        items = { { text = _("加载中…"), enabled = false } },
        close_callback = function()
            desktop._filter_menu = nil
        end,
    }

    local source = desktop.source
    local generation = desktop.source_generation or 0
    if not source or not source.configured or not source:configured() or not source.filtersAsync then
        applyList({})
        return
    end
    source:filtersAsync(function(res, err)
        if desktop._closed or desktop.source ~= source
            or (desktop.source_generation or 0) ~= generation then
            return
        end
        if not res then
            logger.warn("book filters failed", err)
            applyList({})
        end
        if res then
            applyList(pickFilterList(res.data or {}, def))
        end
    end)
end

--- 按当前网格容量同步 page_size。
---@param desktop table
---@return number
function Library.syncPageSize(desktop)
    local m = Library.gridMetrics(
        (desktop.dimen and desktop.dimen.w) or Screen:getWidth(),
        desktop:contentHeight()
    )
    local n = math.max(1, m.page_size or 1)
    if desktop.page_size ~= n then
        desktop.page_size = n
        local pages = math.max(1, math.ceil((desktop.total or 0) / n))
        if (desktop.page or 1) > pages then
            desktop.page = pages
            desktop._library_state = nil
        end
    end
    return desktop.page_size
end

--- 计算图书馆总页数。
---@param desktop table
---@return number
function Library.pages(desktop)
    local ps = Library.syncPageSize(desktop)
    return math.max(1, math.ceil((desktop.total or 0) / ps))
end

--- 跳转到指定页并重建。
---@param desktop table
---@param page number
function Library.gotoPage(desktop, page)
    local pages = Library.pages(desktop)
    page = math.max(1, math.min(pages, tonumber(page) or 1))
    if page == desktop.page and desktop._library_state and desktop._library_state.books then
        return
    end
    desktop.page = page
    desktop._library_state = nil
    desktop.tab = "library"
    desktop:rebuild()
end

--- 清除全部筛选条件。
---@param desktop table
function Library.clearFilters(desktop)
    desktop.filter = {}
    desktop.page = 1
    desktop._library_state = nil
    desktop.tab = "library"
    desktop:rebuild()
end

--- 弹出搜索输入框。
---@param desktop table
function Library.showSearch(desktop)
    local dialog
    dialog = InputDialog:new{
        title = _("搜索书籍"),
        input = (desktop.filter and desktop.filter.search) or "",
        input_hint = _("书名或作者"),
        buttons = {{
            {
                text = _("清除"),
                callback = function()
                    UIManager:close(dialog)
                    Library.applyExclusive(desktop, "search", "")
                end,
            },
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("搜索"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    Library.applyExclusive(desktop, "search", q)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Desktop rebuild 入口：同步 page_size、缺态触发 fetch、拼分页 UI。
---@param desktop table
---@return table
function Library.page(desktop)
    Library.syncPageSize(desktop)
    local state = desktop._library_state
    if not state then
        UIManager:nextTick(function()
            if desktop._closed or desktop.tab ~= "library" then return end
            Library.fetch(desktop)
        end)
    end
    return Library.build(desktop:ctx(), state or {}, {
        page = desktop.page,
        pages = Library.pages(desktop),
        total = desktop.total or 0,
        on_prev = function()
            Library.gotoPage(desktop, desktop.page - 1)
        end,
        on_next = function()
            Library.gotoPage(desktop, desktop.page + 1)
        end,
        on_first = function()
            Library.gotoPage(desktop, 1)
        end,
        on_last = function()
            Library.gotoPage(desktop, Library.pages(desktop))
        end,
    })
end

return Library
