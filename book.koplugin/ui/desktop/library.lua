--[[--
图书馆：可持久化切换书架、分类、系列和阅读状态视图。
  书架顶栏：搜索 / 清除 / 视图 + 右上角总数
  分组视图：先显示分组与数量，点击后进入对应封面书架

布局：
  +-----------------------------------------------+
  | [🔍搜索] [清除] [视图]              共N       |
  | +----+ +----+ +----+ +----+                   |
  | |封面| |封面| |封面| |封面|                   |
  | |书名| |书名| |书名| |书名|                   |
  | +----+ +----+ +----+ +----+                   |
  |                                               |
  |  |«  ‹   Page N of M   ›  »|                  |
  +-----------------------------------------------+

@module koplugin.book.ui.library
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local Surface = require("ui.components.surface")
local Pager = require("ui.components.pager")
local Popup = require("ui.components.popup")
local BookDB = require("db.book")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Library = {}

---@return "flat"|"category"|"series"|"status"
local function viewMode()
    local mode = MoonSettings.get("display").library_view
    if mode == "category" or mode == "series" or mode == "status" then
        return mode
    end
    return "flat"
end

---@param desktop table
---@return boolean
function Library.isGroupIndex(desktop)
    return viewMode() ~= "flat" and desktop._library_group == nil
end

---@param desktop table
---@param mode "flat"|"category"|"series"|"status"
function Library.setView(desktop, mode)
    local display = MoonSettings.get("display")
    display.library_view = mode
    MoonSettings.saveSection("display", display)
    desktop._library_group = nil
    desktop._library_groups_state = nil
    desktop._library_state = nil
    desktop.filter = {}
    desktop.page = 1
    desktop.total = 0
    desktop:rebuild()
end

---@param desktop table
---@param value string 空串表示未分类/无系列
function Library.enterGroup(desktop, value)
    desktop._library_group = { mode = viewMode(), value = value }
    desktop._library_state = nil
    desktop.filter = {}
    desktop.page = 1
    desktop.total = 0
    desktop:rebuild()
end

---@param desktop table
function Library.leaveGroup(desktop)
    desktop._library_group = nil
    desktop._library_state = nil
    desktop.filter = {}
    desktop.page = 1
    local state = desktop._library_groups_state
    desktop.total = state and #(state.groups or {}) or 0
    desktop:rebuild()
end

---@param mode string
---@return table
local function groupDefinition(mode)
    if mode == "series" then
        return {
            data_key = "series_counts", value_key = "series",
            empty_label = _("无系列"), title = _("系列"),
        }
    elseif mode == "status" then
        return {
            data_key = "read_counts", value_key = "status",
            labels = { new = _("新书"), read = _("已读"), unread = _("未读") },
            title = _("阅读状态"),
        }
    end
    return {
        data_key = "category_counts", value_key = "category",
        empty_label = _("未分类"), title = _("分类"),
    }
end

---@param desktop table
function Library.showViewPicker(desktop)
    local current = viewMode()
    local choices = {
        { value = "flat", text = _("书架视图") },
        { value = "category", text = _("分类视图") },
        { value = "series", text = _("系列视图") },
        { value = "status", text = _("阅读状态视图") },
    }
    local items = {}
    for _, choice in ipairs(choices) do
        local value = choice.value
        items[#items + 1] = {
            text = choice.text,
            checked = value == current,
            callback = function() Library.setView(desktop, value) end,
        }
    end
    desktop._library_view_picker = Popup.sheet{
        title = _("图书馆视图"),
        items = items,
        close_callback = function() desktop._library_view_picker = nil end,
    }
end

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
        Surface.pill(content, {
            padding = UI.sz(6),
            width = tw,
            height = th,
            shadow = false,
        }),
    }
    return tap
end

--- 应用书名搜索。
---@param desktop table
---@param value string|nil
function Library.applySearch(desktop, value)
    desktop.filter = value and value ~= "" and { search = value } or {}
    desktop.page = 1
    desktop._library_state = nil
    desktop.tab = "library"
    desktop:rebuild()
end

--- 状态变更后重新查询当前页，确保筛选结果立即收敛。
---@param desktop table
local function refreshPage(desktop)
    desktop._library_state = nil
    desktop:rebuild()
end

---@param ctx table
---@param book Book
local function showBookActions(ctx, book)
    local desktop = ctx.desktop
    local is_read = tonumber(book.read_state) == 1
    Popup.sheet{
        title = BookInfo.title(book),
        items = {
            {
                text = is_read and _("标记为未读") or _("标记为已读"),
                callback = function()
                    if not BookDB.setRead(book.source_id, book.stable_id, not is_read) then
                        UIManager:show(InfoMessage:new{ text = _("更新阅读状态失败") })
                        return
                    end
                    book.read_state = is_read and 2 or 1
                    if desktop then refreshPage(desktop) end
                end,
            },
            {
                text = _("删除"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定删除《%1》？"), BookInfo.title(book)),
                        ok_text = _("删除"),
                        ok_callback = function()
                            local source = ctx.source
                            if not source or type(source.deleteBookAsync) ~= "function" then
                                UIManager:show(InfoMessage:new{ text = _("当前数据源不支持删除本书") })
                                return
                            end
                            source:deleteBookAsync({
                                source_id = book.source_id,
                                stable_id = book.stable_id,
                                book = book,
                                source = source,
                            }, function(ok, err)
                                if not ok then
                                    UIManager:show(InfoMessage:new{
                                        text = err or _("删除本书失败"),
                                    })
                                    return
                                end
                                if desktop then
                                    desktop.page = 1
                                    refreshPage(desktop)
                                end
                            end)
                        end,
                    })
                end,
            },
        },
    }
end

--- 封面 + 单行书名。
---@param ctx table
---@param book table
---@param slot_w number
---@param cw number
---@param ch number
---@param on_open fun(book: table)|nil
---@param show_status boolean|nil
---@return table, number
local function coverCell(ctx, book, slot_w, cw, ch, on_open, show_status)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = true,
        ribbon = show_status ~= false,
        download = show_status ~= false,
        show_parent = ctx.desktop,
    }))
    local title_gap = UI.sz(4)
    local title_h = UI.sz(22)
    local total_h = ch + title_gap + title_h
    local tap = BookInfo.tappable(slot_w, total_h, function()
        if on_open then on_open(book) end
    end, function()
        showBookActions(ctx, book)
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
---@param show_status boolean|nil
---@return table, number
local function buildGrid(ctx, books, m, on_open, show_status)
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
        local cell = coverCell(ctx, book, slot_w, cw, ch, on_open, show_status)
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

---@param w number
---@param h number
---@return table
local function groupMetrics(w, h)
    local pad = UI.sz(10)
    local top_h = UI.sz(52)
    local bottom_h = Pager.bandH()
    local grid_h = math.max(1, h - top_h - bottom_h)
    local cols = w >= 600 and 3 or 2
    local gap = UI.sz(10)
    local slot_w = math.max(1, math.floor((w - pad * 2 - gap * (cols - 1)) / cols))
    local cell_h = UI.sz(76)
    local row_gap = UI.sz(10)
    local rows = math.max(1, math.floor((grid_h + row_gap) / (cell_h + row_gap)))
    return {
        pad = pad, top_h = top_h, bottom_h = bottom_h, grid_h = grid_h,
        cols = cols, gap = gap, row_gap = row_gap, slot_w = slot_w,
        cell_h = cell_h, rows = rows, page_size = cols * rows,
    }
end

---@param ctx table
---@param state table
---@param opts table
---@return table
local function buildGroupPage(ctx, state, opts)
    local w, h = ctx.width, ctx.height
    local m = groupMetrics(w, h)
    local def = groupDefinition(viewMode())
    local groups = state.groups
    local page = opts.page or 1
    local page_size = m.page_size
    local pages = opts.pages or 1
    local total = opts.total or 0

    local tools = HorizontalGroup:new{
        align = "center",
        iconAction("refresh", _("刷新"), function()
            if ctx.desktop then
                Library.rescan(ctx.desktop)
                ctx.desktop._library_groups_state = nil
                ctx.desktop:rebuild()
            end
        end),
        HorizontalSpan:new{ width = UI.sz(8) },
        iconAction("view_module", _("视图"), function()
            if ctx.desktop then Library.showViewPicker(ctx.desktop) end
        end),
    }
    local total_label = TextWidget:new{
        text = T(_("共%1组"), total),
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    }
    local mid = math.max(UI.sz(8), w - m.pad * 2 - tools:getSize().w - total_label:getSize().w)
    local kids = {
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding = m.pad,
            padding_bottom = UI.sz(4),
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = m.top_h },
            HorizontalGroup:new{
                align = "center", tools, HorizontalSpan:new{ width = mid }, total_label,
            },
        },
    }
    local used = m.top_h

    if not groups then
        kids[#kids + 1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = m.grid_h },
            TextWidget:new{ text = _("加载中…"), face = UI.face("xx_smallinfofont", 14), fgcolor = UI.muted() },
        }
        used = used + m.grid_h
    elseif #groups == 0 then
        kids[#kids + 1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = m.grid_h },
            TextWidget:new{ text = state.err or _("没有分组"), face = UI.face("xx_smallinfofont", 14), fgcolor = UI.muted() },
        }
        used = used + m.grid_h
    else
        local grid = VerticalGroup:new{ align = "left" }
        local first = (page - 1) * page_size + 1
        local last = math.min(#groups, first + page_size - 1)
        local index = first
        local rows_used = 0
        for row = 1, m.rows do
            if index > last then break end
            if rows_used > 0 then
                grid[#grid + 1] = VerticalSpan:new{ width = m.row_gap }
                used = used + m.row_gap
            end
            local line = HorizontalGroup:new{}
            line[#line + 1] = HorizontalSpan:new{ width = m.pad }
            for col = 1, m.cols do
                if index > last then break end
                if col > 1 then line[#line + 1] = HorizontalSpan:new{ width = m.gap } end
                local item = groups[index]
                local value = item[def.value_key] or ""
                local name = def.labels and def.labels[value]
                    or (value == "" and def.empty_label or value)
                local content = VerticalGroup:new{
                    align = "center",
                    TextWidget:new{
                        text = name,
                        face = UI.face("cfont", 16),
                        bold = true,
                        max_width = m.slot_w - UI.sz(16),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    },
                    VerticalSpan:new{ width = UI.sz(5) },
                    TextWidget:new{
                        text = T(_("%1 本书"), item.count),
                        face = UI.face("xx_smallinfofont", 12),
                        fgcolor = UI.muted(),
                    },
                }
                local tap = BookInfo.tappable(m.slot_w, m.cell_h, function()
                    Library.enterGroup(ctx.desktop, value)
                end)
                tap[1] = CenterContainer:new{
                    dimen = Geom:new{ w = m.slot_w, h = m.cell_h },
                    Surface.card(content, {
                        width = m.slot_w,
                        height = m.cell_h,
                        padding = UI.sz(8),
                        shadow = false,
                    }),
                }
                line[#line + 1] = tap
                index = index + 1
            end
            grid[#grid + 1] = line
            rows_used = rows_used + 1
            used = used + m.cell_h
        end
        kids[#kids + 1] = grid
    end
    local filler = math.max(0, h - m.bottom_h - used)
    if filler > 0 then
        kids[#kids + 1] = VerticalSpan:new{ width = filler }
    end
    kids[#kids + 1] = Pager.band(w, page, pages, opts)
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(kids),
    }
end

---@param desktop table
function Library.fetchGroups(desktop)
    if desktop._library_fetch_cancel then
        desktop._library_fetch_cancel:cancel()
        desktop._library_fetch_cancel = nil
    end
    local source = desktop.source
    local generation = desktop.source_generation or 0
    local mode = viewMode()
    local def = groupDefinition(mode)
    if not source or type(source.filtersAsync) ~= "function" then
        desktop._library_groups_state = { groups = {}, err = _("当前数据源不支持分组") }
        desktop:rebuild()
        return
    end
    desktop._library_fetch_cancel = source:filtersAsync(function(res, err)
        if desktop._closed or desktop.source ~= source
            or (desktop.source_generation or 0) ~= generation
            or not Library.isGroupIndex(desktop) or viewMode() ~= mode then
            return
        end
        desktop._library_fetch_cancel = nil
        local data = res and res.data or {}
        local groups = data[def.data_key] or {}
        desktop._library_groups_state = {
            groups = groups,
            err = res and nil or (err or _("加载失败")),
        }
        desktop.total = #groups
        desktop:rebuild()
    end)
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
    --- 点封面进书籍详情页。
    ---@param book Book 被点中的书
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end

    local tools_kids = { align = "center" }
    local caps = (ctx.source and ctx.source.capabilities and ctx.source:capabilities()) or {}
    local search_only = opts.search_only == true
    local group_drill = opts.group_drill == true
    local has_tool = false
    if group_drill then
        local group = ctx.desktop and ctx.desktop._library_group
        local title = groupDefinition(group and group.mode or viewMode()).title
        table.insert(tools_kids, iconAction("arrow_back", T(_("返回%1"), title), function()
            if ctx.desktop then Library.leaveGroup(ctx.desktop) end
        end))
        has_tool = true
    elseif not search_only and caps.refresh then
        table.insert(tools_kids, iconAction("refresh", _("刷新"), function()
            if ctx.desktop then Library.rescan(ctx.desktop) end
        end))
        has_tool = true
        if caps.search then
            table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
        end
    end
    if not group_drill and (search_only or caps.search) then
        table.insert(tools_kids, iconAction("search", _("搜索"), function()
            if opts.on_search then
                opts.on_search()
            elseif ctx.desktop then
                Library.showSearch(ctx.desktop)
            end
        end))
        has_tool = true
    end
    if not group_drill and (search_only or caps.search) and (not search_only or opts.on_clear) then
        table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
        table.insert(tools_kids, iconAction("clear", _("清除"), function()
            if opts.on_clear then
                opts.on_clear()
            elseif ctx.desktop then
                Library.clearFilters(ctx.desktop)
            end
        end))
    end
    if not search_only and not group_drill then
        if has_tool then
            table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
        end
        table.insert(tools_kids, iconAction("view_module", _("视图"), function()
            if ctx.desktop then Library.showViewPicker(ctx.desktop) end
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
        local grid, grid_h = buildGrid(ctx, books, m, on_open, opts.show_status)
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
    local group = desktop._library_group
    local category = f.category or ""
    local uncategorized = false
    local series = f.series or ""
    local unseries = false
    local read_status = f.read_status or ""
    if group and group.mode == "category" then
        category = group.value
        uncategorized = group.value == ""
    elseif group and group.mode == "series" then
        series = group.value
        unseries = group.value == ""
    elseif group and group.mode == "status" then
        read_status = group.value
    end
    if not source then done({}, _("当前数据源不可用")); return end
    if not source.listLibraryAsync then
        done({}, _("当前数据源不支持书库"))
        return
    end
    desktop._library_fetch_cancel = source:listLibraryAsync({
        page = page,
        page_size = page_size,
        search = search,
        category = category,
        uncategorized = uncategorized,
        series = series,
        unseries = unseries,
        read_status = read_status,
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
        done(books)
    end)
end

--- 按当前网格容量同步 page_size。
---@param desktop table
---@return number
function Library.syncPageSize(desktop)
    local width = (desktop.dimen and desktop.dimen.w) or Screen:getWidth()
    local height = desktop:contentHeight()
    local m = Library.isGroupIndex(desktop)
        and groupMetrics(width, height)
        or Library.gridMetrics(width, height)
    local n = math.max(1, m.page_size or 1)
    if desktop.page_size ~= n then
        desktop.page_size = n
        desktop._library_state = nil
        local pages = math.max(1, math.ceil((desktop.total or 0) / n))
        if (desktop.page or 1) > pages then
            desktop.page = pages
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
    local group_index = Library.isGroupIndex(desktop)
    local state_ready = group_index
        and desktop._library_groups_state
        and desktop._library_groups_state.groups
        or desktop._library_state and desktop._library_state.books
    if page == desktop.page and state_ready then
        return
    end
    desktop.page = page
    desktop.tab = "library"
    if group_index then
        desktop:rebuild()
        return
    end
    desktop._library_state = nil
    desktop:rebuild()
end

--- 手动强制刷新书库；具体动作由当前源决定（本地源扫盘，远端源拉全量）。
---@param desktop table
function Library.rescan(desktop)
    local source = desktop.source
    if not source or not source.syncBooksAsync then return end
    if desktop.plugin and desktop.plugin.emitToSource then
        desktop.plugin:emitToSource("library_refresh_request", desktop, source)
    end
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
---@param on_apply fun(query: string)|nil
---@param initial_query string|nil
function Library.showSearch(desktop, on_apply, initial_query)
    --- 提交搜索词；调用方没给 on_apply 时落到书库的独占搜索筛选。
    ---@param query string 搜索词，空串表示清除
    local function apply(query)
        if on_apply then
            on_apply(query)
        else
            Library.applySearch(desktop, query)
        end
    end
    local dialog
    dialog = InputDialog:new{
        title = _("搜索书籍"),
        input = initial_query or (desktop.filter and desktop.filter.search) or "",
        input_hint = _("书名或作者"),
        buttons = {{
            {
                text = _("清除"),
                callback = function()
                    UIManager:close(dialog)
                    apply("")
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
                    apply(q)
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
    if Library.isGroupIndex(desktop) then
        local group_state = desktop._library_groups_state
        if not group_state then
            UIManager:nextTick(function()
                if desktop._closed or desktop.tab ~= "library"
                    or not Library.isGroupIndex(desktop) then return end
                Library.fetchGroups(desktop)
            end)
        end
        return buildGroupPage(desktop:ctx(), group_state or {}, {
            page = desktop.page,
            pages = Library.pages(desktop),
            total = desktop.total or 0,
            on_prev = function() Library.gotoPage(desktop, desktop.page - 1) end,
            on_next = function() Library.gotoPage(desktop, desktop.page + 1) end,
            on_first = function() Library.gotoPage(desktop, 1) end,
            on_last = function() Library.gotoPage(desktop, Library.pages(desktop)) end,
        })
    end
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
        group_drill = desktop._library_group ~= nil,
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
