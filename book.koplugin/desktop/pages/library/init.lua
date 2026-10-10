--[[--
图书馆：平铺封面书架 + 筛选/搜索/排序。

布局：
  +-----------------------------------------------+
  | [刷新] [筛选] [搜索] [清除]              共N  |
  | +----+ +----+ +----+ +----+                   |
  | |封面| |封面| |封面| |封面|                   |
  | |书名| |书名| |书名| |书名|                   |
  | +----+ +----+ +----+ +----+                   |
  |                                               |
  | [<]              N / M                   [>]  |
  +-----------------------------------------------+

@module koplugin.book.ui.library
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CoverCell = require("ui.widgets.cover")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Input = require("ui.themes.widgets.input")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookLibrary
---@field desktop BookDesktop
---@field filter table
---@field sort string
---@field page number
---@field page_size number
---@field total number
---@field state table|nil
---@field fetch_cancel CancelHandle|nil
---@field filter_cancel CancelHandle|nil
---@field _opening_cover table|nil
---@field _opening_bar table|nil
---@field _open_token table|nil
---@field _verify_job table|nil 下载标记后台校验任务
local Library = {}
Library.__index = Library

--- 创建图书馆实例，独立持有筛选、分页和请求句柄。
---@param opts table
---@return BookLibrary
function Library:new(opts)
    opts.filter = opts.filter or {}
    opts.page = opts.page or 1
    opts.page_size = opts.page_size or 12
    opts.total = opts.total or 0
    opts.sort = opts.sort or (MoonSettings.get("desktop").library_sort or "recent_added")
    return setmetatable(opts, self)
end

function Library:showFilter()
    local source = self.desktop.source
    if not source then return end
    if self.filter_cancel then self.filter_cancel:cancel(); self.filter_cancel = nil end
    self.filter_cancel = source:filtersAsync(function(res, err)
        self.filter_cancel = nil
        if self.desktop.closed or self.desktop.tab ~= "library"
            or self.desktop.source ~= source then return end
        if not res then
            require("ui.themes.widgets.toast"):new{ text = err or _("加载失败"), timeout = 2 }:show()
            return
        end
        require("desktop.pages.library.filter").open{
            data = res.data,
            current = self.filter,
            sort = self.sort,
            on_apply = function(filter, sort)
                self.filter = filter
                self.sort = sort or "recent_added"
                local display = MoonSettings.get("desktop")
                display.library_sort = self.sort
                MoonSettings.save("desktop", display)
                self.page, self.state = 1, nil
                self.desktop:updateView()
            end,
        }
    end)
end

--- 应用书名搜索。
---@param value string|nil 当前设置项的值
function Library:applySearch(value)
    self.filter = value and value ~= "" and { search = value } or {}
    self.page = 1
    self.state = nil
    self.desktop:updateView()
end

--- 按内容区尺寸算出网格容量；请求 page_size 必须与此一致。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@return table
function Library.gridMetrics(w, h)
    local t = Theme.current()
    w = math.max(1, w)
    h = math.max(1, h)
    local pad = Theme.px(t.space.md)
    local top_h = Theme.px(t.control.height) + Theme.px(t.space.sm) * 2
    local bottom_h = Theme.px(t.control.height)
    local grid_h = math.max(1, h - top_h - bottom_h)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, gap, row_gap, cell_h = CoverCell.denseCoverMetrics(avail, grid_h, {
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

--- 按网格度量铺满一页封面格子（放不下的整行丢弃）。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param books table 按展示顺序排列的书籍列表
---@param m table 预先计算的网格布局尺寸
---@param on_open fun(book: table, cover: table, cw: number, ch: number)
---@param show_status boolean|nil 是否显示书籍状态信息
---@return table
local function buildGrid(ctx, books, m, on_open, show_status)
    local grid = VerticalGroup:new{ align = "left" }
    local rows = math.min(m.rows, math.ceil(#books / m.cols))
    for r = 1, rows do
        if r > 1 then grid[#grid + 1] = VerticalSpan:new{ width = m.row_gap } end
        local row = HorizontalGroup:new{ HorizontalSpan:new{ width = m.pad } }
        for c = 1, m.cols do
            local book = books[(r - 1) * m.cols + c]
            if not book then break end
            if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = m.gap } end
            row[#row + 1] = CoverCell.build(ctx, book, m.slot_w, m.cw, m.ch, on_open, show_status)
        end
        grid[#grid + 1] = row
    end
    return grid
end

--- 构建图书馆页 UI（工具栏 + 网格 + 分页）。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param state table 当前页面的数据和分页状态
---@param opts table|nil 书城页传 on_open 接管点击、on_back 出现「上级」、search_only 只留搜索/清除
---@return table
function Library:build(ctx, state, opts)
    opts = opts or {}
    local t = Theme.current()
    local w, h = ctx.width, ctx.height
    local m = Library.gridMetrics(w, h)
    local gap = Theme.px(t.space.sm)
    local on_open = opts.on_open or CoverCell.opener(self, ctx)
    if opts.show_status ~= false then
        ctx.on_detail = function(book)
            require("desktop.detail").open(ctx.desktop, "library", book)
        end
    end

    local actions = {}
    if opts.on_back then
        actions[#actions + 1] = { "arrow_back", _("上级"), opts.on_back }
    end
    if not opts.search_only then
        actions[#actions + 1] = { "refresh", _("刷新"), function() self:rescan() end }
        if ctx.source and ctx.source.filtersAsync then
            actions[#actions + 1] = { "filter_list", _("筛选"), function() self:showFilter() end }
        end
    end
    actions[#actions + 1] = { "search", _("搜索"), opts.on_search or function() self:showSearch() end }
    actions[#actions + 1] = { "clear", _("清除"), opts.on_clear or function() self:applySearch("") end }

    local tools = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = m.pad } }
    for i, a in ipairs(actions) do
        if i > 1 then tools[#tools + 1] = HorizontalSpan:new{ width = gap } end
        tools[#tools + 1] = Button:new{ icon = a[1], text = a[2], callback = a[3] }
    end
    local total = Text.line("caption", T(_("共%1"), opts.total or 0), { color = t.color.muted })
    -- 不能对 tools 调 getSize：HorizontalGroup 会缓存每个子件的偏移，
    -- 后面再追加间距和总数，绘制时 _offsets[i] 是 nil。
    local used = 0
    for _idx, child in ipairs(tools) do used = used + child:getSize().w end
    tools[#tools + 1] = HorizontalSpan:new{
        width = math.max(gap, w - m.pad - used - total:getSize().w),
    }
    tools[#tools + 1] = total

    local books = state.books
    local body
    if books and #books > 0 then
        body = buildGrid(ctx, books, m, on_open, opts.show_status)
    else
        local msg = not books and _("加载中…")
            or state.err or opts.empty_text or _("没有书籍")
        body = CenterContainer:new{
            dimen = Geom:new{ w = w, h = m.grid_h },
            Text.line("body", msg, { color = t.color.muted, width = w - m.pad * 2 }),
        }
    end
    return Box:new{
        style = { bg = t.color.page },
        width = w,
        height = h,
        VerticalGroup:new{
            align = "left",
            CenterContainer:new{ dimen = Geom:new{ w = w, h = m.top_h }, tools },
            body,
            VerticalSpan:new{ width = math.max(0, m.grid_h - body:getSize().h) },
            Pager.widget({
                width = w,
                page = opts.page or 1,
                pages = opts.pages or 1,
                on_prev = opts.on_prev,
                on_next = opts.on_next,
            }),
        },
    }
end

--- 异步拉取图书馆列表。
function Library:fetch()
    --- 写入图书馆状态并重建。
    ---@param books table 按展示顺序排列的书籍列表
    ---@param err string|nil 操作失败的原因
    local function done(books, err)
        if self.desktop.closed or self.desktop.tab ~= "library" then
            return
        end
        self.state = {
            books = books,
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
        downloaded = f.downloaded,
        source_id = f.source_id or "",
        sort = self.sort,
    }, function(res, err)
        if self.desktop.closed or self.desktop.tab ~= "library"
            or self.desktop.source ~= source then
            return
        end
        self.fetch_cancel = nil
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        self.total = res.count
        -- 书变少（删书、对账）后当前页可能越界：退到末页重拉。
        local pages = math.max(1, math.ceil(self.total / self.page_size))
        if self.page > pages then
            self.page = pages
            self:fetch()
            return
        end
        done(res.data)
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
    self.state = nil
    self.desktop:updateView()
end

--- 手动强制刷新书库；具体动作由当前源决定（本地源扫盘，远端源拉全量）。
--- 进度弹窗归任务队列：源把刷新入队并前台跟随，刷新中再点只重新弹出进度。
function Library:rescan()
    local source = self.desktop.source
    if not source or not source.syncBooksAsync then return end
    self:verifyDownloads()
    require("desktop.sync").refresh(self.desktop)
end

--- 后台校验已下载标记（文件可能被手动删掉），撤掉了登记且仍在图书馆就重拉当前页。
--- 离开页面不取消：写库纠正本身要落地，回调只在仍停留图书馆时刷新界面。
function Library:verifyDownloads()
    if self._verify_job then return end
    local scope = require("book.catalog").libraryScope(self.desktop.source.id)
    self._verify_job = require("book.store").verifyDownloadsAsync(scope, function(changed)
        self._verify_job = nil
        local desktop = self.desktop
        if changed == 0 or desktop.closed or desktop.tab ~= "library" then return end
        self.state = nil
        desktop:updateView()
    end)
end

--- 弹出搜索输入框；提交空串等同清除。
---@param on_apply fun(query: string)|nil 调用方没给时落到书库的独占搜索筛选
---@param initial_query string|nil 搜索框初始文字
function Library:showSearch(on_apply, initial_query)
    Input:new{
        title = _("搜索书籍"),
        fields = { { text = initial_query or self.filter.search or "", hint = _("书名或作者") } },
        ok_text = _("搜索"),
        callback = on_apply or function(query) self:applySearch(query) end,
    }:show()
end

--- Desktop 入口：同步 page_size、缺态触发 fetch、拼分页 UI。
---@return table
function Library:updateView()
    self:syncPageSize()
    local state = self.state
    if not state then
        UIManager:nextTick(function()
            if self.desktop.closed or self.desktop.tab ~= "library" then return end
            self:fetch()
        end)
    end
    return self:build(self.desktop:ctx(), state or {}, {
        page = self.page,
        pages = self:pages(),
        total = self.total,
        on_prev = function() self:gotoPage(self.page - 1) end,
        on_next = function() self:gotoPage(self.page + 1) end,
    })
end

--- 仅取消本实例当前的列表查询，并清空请求句柄；同步本身归源管。
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
Library.deactivate = Library.cancel
Library.destroy = Library.cancel

--- 处理换源重置、书架变化和左右滑动分页，忽略不属于图书馆的事件。
---@param event string 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
function Library:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
        return
    end
    if event == "shelf_changed" then
        self.state = nil
        return
    end
    if event ~= "swipe" then return end
    if payload.direction == "west" then
        self:gotoPage(self.page + 1)
    elseif payload.direction == "east" then
        self:gotoPage(self.page - 1)
    end
end

return Library
