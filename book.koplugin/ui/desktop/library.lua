--[[--
图书馆：平铺封面书架 + 筛选/搜索/排序。

布局：
  +-----------------------------------------------+
  | [刷新] [筛选] [搜索] [清除]         共N       |
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
local InputDialog = require("ui/widget/inputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local BookInfo = require("ui.components.bookinfo")
local CoverCell = require("ui.desktop.cover_cell")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local Surface = require("ui.components.surface")
local Pager = require("ui.components.pager")
local View = require("ui.view")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookLibrary : View
---@field desktop BookDesktop
---@field filter table
---@field page number
---@field page_size number
---@field total number
---@field state table|nil
---@field fetch_cancel CancelHandle|nil
---@field filter_cancel CancelHandle|nil
---@field _opening_cover table|nil
---@field _opening_bar table|nil
---@field _open_token table|nil
---@field build fun(self: BookLibrary, ctx: table, state: table, opts: table|nil): table
---@field showSearch fun(self: BookLibrary, on_apply: fun(query: string)|nil, initial_query: string|nil)
---@field cancel fun(self: BookLibrary)
local Library = {}
Library.__index = Library
setmetatable(Library, View)

--- 创建图书馆实例，独立持有筛选、分页和请求句柄。
---@param opts table|nil
---@return BookLibrary
-- 使用 View 继承的 :new，生命周期字段由基类统一初始化。
-- 页面内容仍由现有 updateView 负责拼装。
function Library:new(opts)
    opts = opts or {}
    opts.filter = opts.filter or {}
    opts.page = opts.page or 1
    opts.page_size = opts.page_size or 12
    opts.total = opts.total or 0
    opts.sort = opts.sort or (MoonSettings.get("display").library_sort or "recent_added")
    return View.new(self, opts)
end

function Library:showFilter()
    local source = self.desktop.source
    if not source or not source.filtersAsync then return end
    if self.filter_cancel then self.filter_cancel:cancel(); self.filter_cancel = nil end
    local generation = self.desktop.source_generation or 0
    self.filter_cancel = source:filtersAsync(function(res)
        self.filter_cancel = nil
        if self.desktop.lifecycle.state == "Destroy" or self.desktop.tab ~= "library"
            or self.desktop.source ~= source
            or (self.desktop.source_generation or 0) ~= generation then return end
        require("ui.desktop.library_filter").open{
            data = res and res.data or {},
            current = self.filter,
            sort = self.sort,
            on_apply = function(filter, sort)
                self.filter = filter
                self.sort = sort or "recent_added"
                local display = MoonSettings.get("display")
                display.library_sort = self.sort
                MoonSettings.saveSection("display", display)
                self.page, self.state = 1, nil
                self.desktop:updateView()
            end,
        }
    end) or nil
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
function Library:applySearch(value)
    self.filter = value and value ~= "" and { search = value } or {}
    self.page = 1
    self.state = nil
    self.desktop.tab = "library"
    self.desktop:updateView()
end

--- 按内容区尺寸算出网格容量；请求 page_size 必须与此一致。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@return table
function Library.gridMetrics(w, h)
    w = math.max(1, w)
    h = math.max(1, h)
    local pad = UI.sz(10)
    local top_h = UI.sz(52)
    local bottom_h = Pager.bandH()
    local grid_h = math.max(1, h - top_h - bottom_h)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, gap, row_gap, cell_h = UI.denseCoverMetrics(avail, grid_h, {
        title_extra = CoverCell.titleExtra(),
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
---@param on_open fun(book: table, cover: table, cw: number, ch: number)
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
        local cell = CoverCell.build(ctx, book, slot_w, cw, ch, on_open, show_status)
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
    local on_open = CoverCell.opener(self, ctx)
    if opts.show_status == false then
        on_open = function(book)
            CoverCell.openDetail(ctx, book)
        end
    end

    local tools_kids = { align = "center" }
    local search_only = opts.search_only == true
    if not search_only then
        table.insert(tools_kids, iconAction("refresh", _("刷新"), function()
            self:rescan()
        end))
        table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
    end
    local supports_filter = ctx.source and type(ctx.source.filtersAsync) == "function"
    if not search_only and supports_filter then
        table.insert(tools_kids, iconAction("filter_list", _("筛选"), function()
            self:showFilter()
        end))
        table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
    end
    table.insert(tools_kids, iconAction("search", _("搜索"), opts.on_search or function()
        self:showSearch()
    end))
    table.insert(tools_kids, HorizontalSpan:new{ width = UI.sz(8) })
    table.insert(tools_kids, iconAction("clear", _("清除"), opts.on_clear or function()
        self:applySearch("")
    end))
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

    local kids = { align = "left", top }
    local used = m.top_h
    local band_h = m.bottom_h

    --- 空态/加载占位。
    ---@param msg string 需要显示的提示文字
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
    table.insert(kids, Pager.band(w, page, pages, opts))

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
function Library:fetch()
    --- 写入图书馆状态并重建。
    ---@param books table|nil 按展示顺序排列的书籍列表
    ---@param err string|nil 操作失败的原因
    local function done(books, err)
        if self.desktop.lifecycle.state == "Destroy" or self.desktop.tab ~= "library" then
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
    local f = self.filter
    if not source then done({}, _("当前数据源不可用")); return end
    if not source.listLibraryAsync then
        done({}, _("当前数据源不支持书库"))
        return
    end
    self.fetch_cancel = source:listLibraryAsync({
        page = self.page,
        page_size = self.page_size,
        search = f.search or "",
        category = f.category or "",
        uncategorized = not not f.uncategorized,
        series = f.series or "",
        unseries = not not f.unseries,
        read_status = f.read_status,
        source_id = f.source_id or "",
        sort = self.sort,
    }, function(res, err)
        if self.desktop.lifecycle.state == "Destroy" or self.desktop.tab ~= "library"
            or self.desktop.source ~= source or (self.desktop.source_generation or 0) ~= generation then
            return
        end
        self.fetch_cancel = nil
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        self.total = tonumber(res.count) or 0
        done(res.data or {})
    end)
end

--- 按当前网格容量同步 page_size。
---@return number
function Library:syncPageSize()
    local desktop = self.desktop
    local n = Library.gridMetrics(desktop.dimen.w, desktop:contentHeight()).page_size
    if self.page_size ~= n then
        self.page_size = n
        self.state = nil
        local pages = math.max(1, math.ceil(self.total / n))
        if self.page > pages then
            self.page = pages
        end
    end
    return self.page_size
end

--- 计算图书馆总页数。
---@return number
function Library:pages()
    return math.max(1, math.ceil(self.total / self:syncPageSize()))
end

--- 跳转到指定页并重建。
---@param page number 当前页码，从 1 开始
function Library:gotoPage(page)
    local pages = self:pages()
    page = math.max(1, math.min(pages, page))
    if page == self.page and self.state and self.state.books then
        return
    end
    self.page = page
    self.desktop.tab = "library"
    self.state = nil
    self.desktop:updateView()
end

--- 手动强制刷新书库；具体动作由当前源决定（本地源扫盘，远端源拉全量）。
function Library:rescan()
    local source = self.desktop.source
    if not source or not source.syncBooksAsync then return end
    if self.desktop.plugin and self.desktop.plugin.emitToSource then
        self.desktop.plugin:emitToSource("library_refresh_request", self.desktop, source)
    end
end

--- 弹出搜索输入框。
---@param on_apply fun(query: string)|nil 调用方没给时落到书库的独占搜索筛选
---@param initial_query string|nil 搜索框初始文字
function Library:showSearch(on_apply, initial_query)
    local apply = on_apply or function(query)
        self:applySearch(query)
    end
    local dialog
    dialog = InputDialog:new{
        title = _("搜索书籍"),
        input = initial_query or self.filter.search or "",
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
    local state = self.state
    if not state then
        UIManager:nextTick(function()
            if self.desktop.lifecycle.state == "Destroy" or self.desktop.tab ~= "library" then return end
            self:fetch()
        end)
    end
    local widget = self:build(self.desktop:ctx(), state or {}, {
            page = self.page,
            pages = self:pages(),
            total = self.total,
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
    self.widget = widget
    return widget
end

--- 仅取消本实例当前的列表查询，并清空请求句柄。
function Library:cancel()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
    if self.filter_cancel then
        self.filter_cancel:cancel()
        self.filter_cancel = nil
    end
end

--- 取消旧查询并清除筛选、分页及列表缓存。
function Library:reset()
    self:cancel()
    self.filter = {}
    self.page = 1
    self.total = 0
    self.state = nil
end

-- 取消、暂停、销毁都只需停掉在飞查询，避免离开页面后旧结果继续更新界面。
Library.onCancel = Library.cancel
Library.onPause = Library.cancel
Library.onDestroy = Library.cancel

--- 处理换源重置和左右滑动分页，忽略不属于图书馆的事件。
---@param event string 父组件转发的事件名称或事件对象
---@param payload table|nil 与事件一起传入的数据
function Library:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
        return
    end
    if event ~= "swipe" or type(payload) ~= "table" then return end
    if payload.direction == "west" then
        self:gotoPage(self.page + 1)
    elseif payload.direction == "east" then
        self:gotoPage(self.page - 1)
    end
end

return Library
