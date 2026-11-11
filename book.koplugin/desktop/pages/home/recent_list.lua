--[[--
主体：最近阅读书架。

@module koplugin.book.desktop.pages.home.recent_list
--]]

local Book = require("ui.widgets.book")
local CoverCell = require("ui.widgets.cover")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MoonSettings = require("utils.settings")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

local MIN_ROWS, MAX_ROWS, DEFAULT_ROWS = 1, 2, 2
local MIN_COLS, MAX_COLS, DEFAULT_COLS = 3, 8, 4

---@class BookHomeRecentList : BookHomeComponent
---@field page number|nil 当前页码
local M = {
    id = "recent_list",
    label = _("最近阅读列表"),
    icon = "view_list",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

--- 读取最近阅读网格行数；非法值回退到两行。
---@return number
function M.rows()
    local n = math.floor(tonumber(MoonSettings.get("desktop.pages.home").home_recent_list_rows) or DEFAULT_ROWS)
    if n == MIN_ROWS then return MIN_ROWS end
    return MAX_ROWS
end

--- 规范化并保存最近阅读网格行数。
---@param n number|nil
function M.saveRows(n)
    n = math.floor(tonumber(n) or DEFAULT_ROWS)
    if n ~= MIN_ROWS then n = MAX_ROWS end
    local home = MoonSettings.get("desktop.pages.home")
    home.home_recent_list_rows = n
    MoonSettings.save("desktop.pages.home", home)
end

--- 读取最近阅读网格列数；夹到书架列数范围。
---@return number
function M.cols()
    local n = math.floor(tonumber(MoonSettings.get("desktop.pages.home").home_recent_list_cols) or DEFAULT_COLS)
    return math.max(MIN_COLS, math.min(MAX_COLS, n))
end

--- 规范化并保存最近阅读网格列数。
---@param n number|nil
function M.saveCols(n)
    n = math.max(MIN_COLS, math.min(MAX_COLS, math.floor(tonumber(n) or DEFAULT_COLS)))
    local home = MoonSettings.get("desktop.pages.home")
    home.home_recent_list_cols = n
    MoonSettings.save("desktop.pages.home", home)
end

--- 读取封面下是否显示书名；缺省视为显示。
---@return boolean
function M.showTitle()
    return MoonSettings.get("desktop.pages.home").home_recent_list_show_title ~= false
end

--- 规范化并保存封面下是否显示书名。
---@param on boolean|nil
function M.saveShowTitle(on)
    local home = MoonSettings.get("desktop.pages.home")
    home.home_recent_list_show_title = on ~= false
    MoonSettings.save("desktop.pages.home", home)
end

--- 读取封面下是否显示作者；独立开关，不跟图书馆的 library_author。
---@return boolean
function M.showAuthor()
    return MoonSettings.get("desktop.pages.home").home_recent_list_show_author == true
end

--- 规范化并保存封面下是否显示作者。
---@param on boolean|nil
function M.saveShowAuthor(on)
    local home = MoonSettings.get("desktop.pages.home")
    home.home_recent_list_show_author = on == true
    MoonSettings.save("desktop.pages.home", home)
end

--- 是否把第一本（最近读的那本）也排进列表；缺省不排，留给「当前阅读」大卡片。
---@return boolean
function M.showFirst()
    return MoonSettings.get("desktop.pages.home").home_recent_list_show_first == true
end

---@param on boolean
function M.saveShowFirst(on)
    local home = MoonSettings.get("desktop.pages.home")
    home.home_recent_list_show_first = on
    MoonSettings.save("desktop.pages.home", home)
end

--- 列表要显示的书：按设置丢掉已读完；其余在读，开关打开时第一本排在最前。
---@param recent Book|nil
---@param reading Book[]
---@return Book[]
local function listBooks(recent, reading)
    recent, reading = M.withoutFinished(recent, reading)
    if not (recent and M.showFirst()) then return reading end
    local books = { recent }
    for i, book in ipairs(reading) do books[i + 1] = book end
    return books
end

--- 编辑态设置：行数 1/2，列数 3–8，封面下标题开关，是否显示第一本。
---@param desktop BookDesktop
function M:showSettings(desktop)
    --- 保存后走首页刷新，列数变化时高度不变也必须重建网格。
    local function refresh()
        desktop:onEvent("home_refresh")
    end
    require("ui.themes.widgets.settings"):new{
        title = M.label,
        items = function(page)
            return {
                {
                    title = _("行数"),
                    items = {
                        { value = MIN_ROWS, text = _("一行") },
                        { value = MAX_ROWS, text = _("两行") },
                    },
                    current = M.rows(),
                    on_select = function(value)
                        if M.rows() == value then return end
                        M.saveRows(value)
                        refresh()
                    end,
                },
                { title = T(_("每行 %1 本"), M.cols()), chevron = true, callback = function()
                    require("ui.themes.widgets.spin"):new{
                        title = _("每行数量"),
                        fields = { { value = M.cols(), min = MIN_COLS, max = MAX_COLS } },
                        callback = function(value)
                            M.saveCols(value)
                            refresh()
                            page:updateView()
                        end,
                    }:show()
                    return false
                end },
                { title = _("显示标题"), toggle = true, checked = M.showTitle(),
                    callback = function()
                        M.saveShowTitle(not M.showTitle())
                        refresh()
                    end },
                { title = _("显示作者"), toggle = true, checked = M.showAuthor(),
                    callback = function()
                        M.saveShowAuthor(not M.showAuthor())
                        refresh()
                    end },
                { title = _("显示第一本"), toggle = true, checked = M.showFirst(),
                    callback = function()
                        M.saveShowFirst(not M.showFirst())
                        refresh()
                    end },
                { title = _("隐藏已读完"), toggle = true, checked = M.hideFinished(),
                    callback = function()
                        M.saveHideFinished(not M.hideFinished())
                        refresh()
                    end },
            }
        end,
    }:show()
end

--- 按用户列数算封面；固定列时 denseCoverMetrics 不会加列压高，这里自己封顶。
--- area_h 有值时再收到「行×列刚好装进分配高度」：页溢出缩放后仍按完整行列画
--- 会画出屏幕 BB，模拟器直接 SIGSEGV。
---@param width number 目标宽度，单位像素
---@param area_h number|nil 封面网格可用高度，单位像素
---@return number slot_w
---@return number cw
---@return number ch
---@return number cols
---@return number gap
---@return number row_gap
---@return number cell_h
local function gridMetrics(width, area_h)
    local cols = M.cols()
    local lib = CoverCell.libraryConf()
    local extra = Book.captionExtra(M.showTitle(), M.showAuthor(), lib.kobo)
    -- 单行时宽度决定封面尺寸；用剩余高度压缩会留下无意义的横向空隙。
    -- 多行才需要受区域高度约束，避免整组网格溢出。
    local max_h = M.rows() == 1 and math.huge or CoverCell.gridCoverMaxH(area_h)
    local slot_w, cw, ch, _cols, gap, row_gap, cell_h = CoverCell.denseCoverMetrics(
        math.max(1, width), 0, {
        title_extra = extra,
        max_h = max_h,
        min_cols = cols,
        max_cols = cols,
    })
    if ch > max_h then
        ch = max_h
        cw = CoverCell.stretchW(slot_w, math.max(1, math.min(slot_w, math.floor(ch * 2 / 3))), ch)
        cell_h = ch + extra
    end
    area_h = area_h or 0
    local rows = M.rows()
    if area_h > 0 and rows > 1 then
        local gaps = row_gap * math.max(0, rows - 1)
        local need = cell_h * rows + gaps
        if need > area_h then
            local fit_cell = math.max(1, math.floor((area_h - gaps) / rows))
            ch = math.max(1, math.min(ch, fit_cell - extra))
            cw = CoverCell.stretchW(slot_w, math.max(1, math.min(slot_w, math.floor(ch * 2 / 3))), ch)
            cell_h = math.min(ch + extra, fit_cell)
        end
    end
    return slot_w, cw, ch, cols, gap, row_gap, cell_h
end

--- 区块标题行高（caption 实测 + xs 下边距）。
---@return number
local function sectionHeight()
    return Text.line("caption", "0"):getSize().h + Theme.px(Theme.current().space.xs)
end

--- 按所选行列计算内容高度。分页条始终占位：单页也画出按钮，底部才不是一条空的。
---@param _ctx table 构建上下文
---@param opts table 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table
function M:heightRange(_ctx, opts)
    local _slot_w, _cw, _ch, _cols, _gap, row_gap, cell_h = gridMetrics(opts.width)
    local pager = Theme.px(Theme.current().control.height)
    local h = sectionHeight() + pager + cell_h + (M.rows() - 1) * (row_gap + cell_h)
    -- 封面网格会按分配高度缩小；页放不下时压这里，别压时钟 / 统计那种固定内容。
    return { height = h, shrink = true }
end

--- 按当前分页选取书籍并组装封面网格，返回布局和分页信息。
---@param ctx BookDesktopCtx 构建上下文，提供尺寸、数据源和桌面宿主
---@param books Book[] 按展示顺序排列的书籍列表
---@param width number 目标宽度，单位像素
---@param grid_h number 网格区域高度，单位像素
---@param page number 当前页码，从 1 开始
---@param on_open fun(book: Book, cover: table, cw: number, ch: number)
---@return table
---@return number
---@return number
---@return number
local function buildGrid(ctx, books, width, grid_h, page, on_open)
    local slot_w, cw, ch, cols, gap, row_gap, cell_h = gridMetrics(width, grid_h)
    local lib = CoverCell.libraryConf()
    local rows = M.rows()
    local page_size = math.max(1, cols * rows)
    local pages = math.max(1, math.ceil(#books / page_size))
    page = math.max(1, math.min(page, pages))
    local first = (page - 1) * page_size + 1
    local last = math.min(#books, first + page_size - 1)
    local grid = VerticalGroup:new{ align = "left" }
    local row = HorizontalGroup:new{}
    local col = 0
    local used = 0

    --- 把当前累计的网格单元打包为一行并清空行缓冲。
    local function flushRow()
        if used > 0 then
            table.insert(grid, VerticalSpan:new{ width = row_gap })
            used = used + row_gap
        end
        table.insert(grid, row)
        used = used + cell_h
        row = HorizontalGroup:new{}
        col = 0
    end

    for i = first, last do
        if col > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, (CoverCell.build(ctx, books[i], slot_w, cw, ch, on_open, true, M.showTitle(), M.showAuthor(), lib)))
        col = col + 1
        if col == cols then flushRow() end
    end
    if col > 0 then flushRow() end
    return grid, used, page, pages
end

--- 根据可用空间组装最近阅读封面网格和分页条。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local t = Theme.current()
    local w, h = opts.width, opts.height
    local recent, reading = self:shelf()
    local books = listBooks(recent, reading)
    local pager_h = Theme.px(t.control.height)
    local section_h = sectionHeight()
    local grid_h = math.max(1, h - section_h - pager_h)
    local page, pages = 1, 1
    local content
    if #books > 0 then
        local grid, used
        ctx.on_detail = function(book)
            require("desktop.detail").open(ctx.desktop, "library", book)
        end
        grid, _used, page, pages = buildGrid(ctx, books, w, grid_h, self.page or 1, CoverCell.opener(self, ctx, require("desktop.open").book))
        -- 按格子真实高度留白。用 cell_h 记账会在格子更高时再垫一行，整列就高出分配高度。
        content = VerticalGroup:new{ align = "left", grid, VerticalSpan:new{ width = math.max(0, grid_h - grid:getSize().h) } }
    else
        content = CenterContainer:new{
            dimen = Geom:new{ w = w, h = grid_h },
            Text.line("caption", _("没有在读的书"), { color = t.color.muted }),
        }
    end
    self.page = page

    local label = #books > 0 and T(_("最近阅读 · %1"), #books) or _("最近阅读")
    local col = VerticalGroup:new{
        align = "left",
        Text.line("caption", label, { width = w,
            color = Theme.chrome(), bold = true }),
        VerticalSpan:new{ width = Theme.px(t.space.xs) },
        content,
        Pager.widget({
            width = w,
            page = page,
            pages = pages,
            keys = false,
            on_page = function(target) self.page = target; self:refresh() end,
        }),
    }
    return col
end

--- 换源回到第一页。分页条始终在，书架变化只重建自己。
---@param event string|table 从父视图转发的事件标识或事件对象
function M:onEvent(event)
    if event == "source_changed" then self.page = nil end
    require("desktop.pages.home.base").onEvent(self, event)
end

return M
