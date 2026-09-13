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
local Popup = require("ui.views.popup")
local View = require("ui.view")
local BookDB = require("db.book")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Library = {}
Library.__index = Library
setmetatable(Library, View)

---@class BookLibrary
---@field desktop BookDesktop
---@field filter table
---@field page number
---@field page_size number
---@field total number
---@field group table|nil
---@field groups_state table|nil
---@field state table|nil
---@field fetch_cancel table|nil
---@field view_picker table|nil

--- 创建图书馆实例，独立持有筛选、分组、分页和请求句柄。
---@param desktop BookDesktop 所属桌面实例
---@return BookLibrary
-- 使用 View 继承的 :new，生命周期字段由基类统一初始化。
-- 页面内容仍由现有 updateView 负责拼装。
function Library:new(opts)
    opts = opts or {}
    opts.desktop = opts.desktop or opts[1]
    opts.filter = opts.filter or {}
    opts.page = opts.page or 1
    opts.page_size = opts.page_size or 12
    opts.total = opts.total or 0
    opts.fetch_cancel = opts.fetch_cancel
    return View.new(self, opts)
end
Library.new = function(desktop)
    return Library:new{ desktop = desktop, name = "library" }
end

--- 从桌面取得其拥有的图书馆实例；无桌面时返回 nil。
---@param desktop BookDesktop|nil 所属桌面实例
---@return BookLibrary|nil library 所属图书馆实例
local function libraryOf(desktop)
    return desktop and desktop.library
end


--- 读取已保存的图书馆视图模式，未知值回退到平铺书架。
---@return "flat"|"category"|"series"|"status"
local function viewMode()
    local mode = MoonSettings.get("display").library_view
    if mode == "category" or mode == "series" or mode == "status" then
        return mode
    end
    return "flat"
end

--- 判断是否处于分组视图的索引页，而不是某个分组内部。
---@return boolean
function Library:isGroupIndex()
    return viewMode() ~= "flat" and self.group == nil
end

--- 保存新的书架视图模式，清空旧筛选和分组状态后刷新桌面。
---@param mode "flat"|"category"|"series"|"status" 当前布局、筛选或展示模式
---@return nil
function Library:setView(mode)
    local display = MoonSettings.get("display")
    display.library_view = mode
    MoonSettings.saveSection("display", display)
    self.group = nil
    self.groups_state = nil
    self.state = nil
    self.filter = {}
    self.page = 1
    self.total = 0
    self.desktop:updateView()
end

--- 进入选定分组，重置书籍列表和分页后刷新桌面。
---@param value string 空串表示未分类/无系列
---@return nil
function Library:enterGroup(value)
    self.group = { mode = viewMode(), value = value }
    self.state = nil
    self.filter = {}
    self.page = 1
    self.total = 0
    self.desktop:updateView()
end

--- 退出分组并恢复分组索引页的总数和初始分页。
---@return nil
function Library:leaveGroup()
    self.group = nil
    self.state = nil
    self.filter = {}
    self.page = 1
    local state = self.groups_state
    self.total = state and #(state.groups or {}) or 0
    self.desktop:updateView()
end

--- 取得分类、系列或阅读状态分组使用的数据字段和显示文案。
---@param mode string 当前布局、筛选或展示模式
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

--- 显示书架视图模式菜单，选择后应用并持久化模式。
---@return nil
function Library:showViewPicker()
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
            callback = function() self:setView(value) end,
        }
    end
    self.view_picker = Popup.sheet{
        title = _("图书馆视图"),
        items = items,
        close_callback = function() self.view_picker = nil end,
    }
end

--- 顶栏入口：图标 + 文字，无边框。
---@param icon_name string 图标名称；nil 时按纯文字处理
---@param text string 需要展示的文字
---@param callback fun()|nil 用户触发操作后执行的回调
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
        Surface.build{ child = content, options = {
            padding = UI.sz(6),
            width = tw,
            height = th,
            shadow = false,
        }, kind = "pill" },
    }
    return tap
end

--- 应用书名搜索。
---@param value string|nil 当前设置项的值
---@return nil
function Library:applySearch(value)
    self.filter = value and value ~= "" and { search = value } or {}
    self.page = 1
    self.state = nil
    self.desktop.tab = "library"
    self.desktop:updateView()
end

--- 状态变更后重新查询当前页，确保筛选结果立即收敛。
---@param library BookLibrary 拥有筛选和查询状态的图书馆实例
---@return nil
local function refreshPage(library)
    library.state = nil
    library.desktop:updateView()
end

--- 打开书籍操作菜单，操作完成后刷新当前筛选结果。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param book Book 当前操作或展示的书籍数据
---@return nil
local function showBookActions(ctx, book)
    local desktop = ctx.desktop
    local library = libraryOf(desktop)
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
                    if is_read then
                        book.read_state = 2
                    else
                        book.read_state = 1
                        book.percent = 100
                    end
                    if library then refreshPage(library) end
                end,
            },
            {
                text = _("清理缓存"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定清理《%1》的缓存？"), BookInfo.title(book)),
                        ok_text = _("清理"),
                        ok_callback = function()
                            UIManager:show(InfoMessage:new{ text = _("正在清理缓存…"), timeout = 1 })
                            require("book.cache").clearBookAsync(book.source_id, book.stable_id, function(ok)
                                if desktop and desktop._closed then return end
                                if ok then
                                    local source = ctx.source
                                    if source and source.clearCaches then
                                        source:clearCaches()
                                    end
                                    if library then refreshPage(library) end
                                end
                                UIManager:show(InfoMessage:new{
                                    text = ok and _("已清理") or _("清理失败"),
                                    timeout = 2,
                                })
                            end)
                        end,
                    })
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
                                if library then
                                    library.page = 1
                                    refreshPage(library)
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
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param book table 当前操作或展示的书籍数据
---@param slot_w number 单个封面槽位宽度，单位像素
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@param on_open fun(book: table)|nil
---@param show_status boolean|nil 是否显示书籍状态信息
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
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
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
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param books table 按展示顺序排列的书籍列表
---@param m table 预先计算的网格布局尺寸
---@param on_open fun(book: table)|nil
---@param show_status boolean|nil 是否显示书籍状态信息
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
    ---@return nil
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

--- 根据可用宽高计算图书馆分组卡片的行列和分页容量。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
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

--- 按当前分组数据构建卡片页，并连接进入分组的点击回调。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param state table 当前页面的数据和分页状态
---@param opts table 布局尺寸、样式及行为选项；缺省项使用组件默认值
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
            local library = libraryOf(ctx.desktop)
            if library then
                library:rescan()
                library.groups_state = nil
                library.desktop:updateView()
            end
        end),
        HorizontalSpan:new{ width = UI.sz(8) },
        iconAction("view_module", _("视图"), function()
            if ctx.desktop then libraryOf(ctx.desktop):showViewPicker() end
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
                    libraryOf(ctx.desktop):enterGroup(value)
                end)
                tap[1] = CenterContainer:new{
                    dimen = Geom:new{ w = m.slot_w, h = m.cell_h },
                    Surface.build{ child = content, options = {
                        width = m.slot_w,
                        height = m.cell_h,
                        padding = UI.sz(8),
                        shadow = false,
                    }, kind = "card" },
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

--- 查询分组统计，维护加载状态并在结果返回后刷新索引页。
---@return nil
function Library:fetchGroups()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
    local source = self.desktop.source
    local generation = self.desktop.source_generation or 0
    local mode = viewMode()
    local def = groupDefinition(mode)
    if not source or type(source.filtersAsync) ~= "function" then
        self.groups_state = { groups = {}, err = _("当前数据源不支持分组") }
        self.desktop:updateView()
        return
    end
    self.fetch_cancel = source:filtersAsync(function(res, err)
        if self.desktop._closed or self.desktop.source ~= source
            or (self.desktop.source_generation or 0) ~= generation
            or not self:isGroupIndex() or viewMode() ~= mode then
            return
        end
        self.fetch_cancel = nil
        local data = res and res.data or {}
        local groups = data[def.data_key] or {}
        self.groups_state = {
            groups = groups,
            err = res and nil or (err or _("加载失败")),
        }
        self.total = #groups
        self.desktop:updateView()
    end)
end

--- 构建图书馆页 UI（工具栏 + 网格 + 分页）。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param state table 当前页面的数据和分页状态
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table
function Library:build(ctx, state, opts)
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
        local group = ctx.desktop and ctx.desktop.library.group
        local title = groupDefinition(group and group.mode or viewMode()).title
        table.insert(tools_kids, iconAction("arrow_back", T(_("返回%1"), title), function()
            if ctx.desktop then libraryOf(ctx.desktop):leaveGroup() end
        end))
        has_tool = true
    elseif not search_only and caps.refresh then
        table.insert(tools_kids, iconAction("refresh", _("刷新"), function()
            if ctx.desktop then libraryOf(ctx.desktop):rescan() end
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
                libraryOf(ctx.desktop):showSearch()
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
                libraryOf(ctx.desktop):clearFilters()
            end
        end))
    end
    if not search_only and not group_drill then
        if has_tool then
            table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
        end
        table.insert(tools_kids, iconAction("view_module", _("视图"), function()
            if ctx.desktop then libraryOf(ctx.desktop):showViewPicker() end
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
    ---@param msg string 需要显示的提示文字
    ---@return nil
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
---@return nil
function Library:fetch()
    --- 写入图书馆状态并重建。
    ---@param books table|nil 按展示顺序排列的书籍列表
    ---@param err string|nil 操作失败的原因
    ---@return nil
    local function done(books, err)
        if self.desktop._closed or self.desktop.tab ~= "library" then
            return
        end
        self.state = {
            books = books or {},
            err = err,
        }
        self.desktop:updateView()
    end

    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end

    self:syncPageSize()
    local source = self.desktop.source
    local generation = self.desktop.source_generation or 0
    local page = self.page or 1
    local page_size = self.page_size or 1
    local f = self.filter or {}
    local search = f.search or ""
    local group = self.group
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
    self.fetch_cancel = source:listLibraryAsync({
        page = page,
        page_size = page_size,
        search = search,
        category = category,
        uncategorized = uncategorized,
        series = series,
        unseries = unseries,
        read_status = read_status,
    }, function(res, err)
        if self.desktop._closed or self.desktop.tab ~= "library"
            or self.desktop.source ~= source or (self.desktop.source_generation or 0) ~= generation then
            return
        end
        self.fetch_cancel = nil
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        self.total = tonumber(res.count) or 0
        local books = res.data or {}
        done(books)
    end)
end

--- 按当前网格容量同步 page_size。
---@return number
function Library:syncPageSize()
    local width = (self.desktop.dimen and self.desktop.dimen.w) or Screen:getWidth()
    local height = self.desktop:contentHeight()
    local m = self:isGroupIndex()
        and groupMetrics(width, height)
        or Library.gridMetrics(width, height)
    local n = math.max(1, m.page_size or 1)
    if self.page_size ~= n then
        self.page_size = n
        self.state = nil
        local pages = math.max(1, math.ceil((self.total or 0) / n))
        if (self.page or 1) > pages then
            self.page = pages
        end
    end
    return self.page_size
end

--- 计算图书馆总页数。
---@return number
function Library:pages()
    local ps = self:syncPageSize()
    return math.max(1, math.ceil((self.total or 0) / ps))
end

--- 跳转到指定页并重建。
---@param page number 当前页码，从 1 开始
---@return nil
function Library:gotoPage(page)
    local pages = self:pages()
    page = math.max(1, math.min(pages, tonumber(page) or 1))
    local group_index = self:isGroupIndex()
    local state_ready = group_index
        and self.groups_state
        and self.groups_state.groups
        or self.state and self.state.books
    if page == self.page and state_ready then
        return
    end
    self.page = page
    self.desktop.tab = "library"
    if group_index then
        self.desktop:updateView()
        return
    end
    self.state = nil
    self.desktop:updateView()
end

--- 手动强制刷新书库；具体动作由当前源决定（本地源扫盘，远端源拉全量）。
---@return nil
function Library:rescan()
    local source = self.desktop.source
    if not source or not source.syncBooksAsync then return end
    if self.desktop.plugin and self.desktop.plugin.emitToSource then
        self.desktop.plugin:emitToSource("library_refresh_request", self.desktop, source)
    end
end

--- 清除全部筛选条件。
---@return nil
function Library:clearFilters()
    self.filter = {}
    self.page = 1
    self.state = nil
    self.desktop.tab = "library"
    self.desktop:updateView()
end

--- 弹出搜索输入框。
---@param on_apply fun(query: string)|nil
---@param initial_query string|nil 搜索框初始文字
---@return nil
function Library:showSearch(on_apply, initial_query)
    --- 提交搜索词；调用方没给 on_apply 时落到书库的独占搜索筛选。
    ---@param query string 搜索词，空串表示清除
    ---@return nil
    local function apply(query)
        if on_apply then
            on_apply(query)
        else
            self:applySearch(query)
        end
    end
    local dialog
    dialog = InputDialog:new{
        title = _("搜索书籍"),
        input = initial_query or (self.filter and self.filter.search) or "",
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

--- Desktop 入口：同步 page_size、缺态触发 fetch、拼分页 UI。
---@return table
function Library:updateView()
    self:syncPageSize()
    local widget
    if self:isGroupIndex() then
        local group_state = self.groups_state
        if not group_state then
            UIManager:nextTick(function()
                if self.desktop._closed or self.desktop.tab ~= "library"
                    or not self:isGroupIndex() then return end
                self:fetchGroups()
            end)
        end
        widget = buildGroupPage(self.desktop:ctx(), group_state or {}, {
            page = self.page,
            pages = self:pages(),
            total = self.total or 0,
            on_prev = function() self:gotoPage(self.page - 1) end,
            on_next = function() self:gotoPage(self.page + 1) end,
            on_first = function() self:gotoPage(1) end,
            on_last = function() self:gotoPage(self:pages()) end,
        })
    else
        local state = self.state
        if not state then
            UIManager:nextTick(function()
                if self.desktop._closed or self.desktop.tab ~= "library" then return end
                self:fetch()
            end)
        end
        widget = self:build(self.desktop:ctx(), state or {}, {
            page = self.page,
            pages = self:pages(),
            total = self.total or 0,
            group_drill = self.group ~= nil,
            on_prev = function()
                self:gotoPage(self.page - 1)
            end,
            on_next = function()
                self:gotoPage(self.page + 1)
            end,
            on_first = function()
                self:gotoPage(1)
            end,
            on_last = function()
                self:gotoPage(self:pages())
            end,
        })
    end
    self.widget = widget
    return widget
end

--- 仅取消本实例当前的列表查询，并清空请求句柄。
---@return nil
function Library:cancel()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
end

--- 取消旧查询并清除筛选、分组、分页及列表缓存。
---@return nil
function Library:reset()
    self:cancel()
    self.filter = {}
    self.page = 1
    self.total = 0
    self.group = nil
    self.groups_state = nil
    self.state = nil
end

--- 取消图书馆实例的在飞查询，避免离开页面后旧结果继续更新界面。
---@return nil
function Library:onCancel()
    self:cancel()
end

--- 取消图书馆实例的在飞查询，避免离开页面后旧结果继续更新界面。
---@return nil
function Library:onPause()
    self:cancel()
end

--- 取消图书馆实例的在飞查询，避免离开页面后旧结果继续更新界面。
---@return nil
function Library:onStop()
    self:cancel()
end

--- 取消图书馆实例的在飞查询，避免离开页面后旧结果继续更新界面。
---@return nil
function Library:onDestroy()
    self:cancel()
end

--- 处理换源重置和左右滑动分页，忽略不属于图书馆的事件。
---@param event string 父组件转发的事件名称或事件对象
---@param payload table|nil 与事件一起传入的数据
---@return nil
function Library:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
        return
    end
    if event ~= "swipe" or type(payload) ~= "table" then return end
    if payload.direction == "west" then
        self:gotoPage((self.page or 1) + 1)
    elseif payload.direction == "east" then
        self:gotoPage((self.page or 1) - 1)
    end
end


return Library
