--[[--
主体：Kavita 最近阅读（服务端 On Deck）。仿最近阅读列表的封面网格，
数据来自 Kavita 服务器，书籍与漫画都显示（漫画由 kamare 在线读）。

@module koplugin.book.ui.desktop.home.views.kavita_recent
--]]

local CoverCell = require("ui.desktop.cover_cell")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local MoonSettings = require("utils.settings")
local PageStrip = require("ui.components.pagestrip")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local MIN_ROWS, MAX_ROWS, DEFAULT_ROWS = 1, 2, 2
local MIN_COLS, MAX_COLS, DEFAULT_COLS = 3, 8, 4

---@class BookHomeKavitaRecent : BookHomeComponent
---@field error string|nil 最近一次加载失败的原因（有旧数据时仍显示旧数据）
local M = {
    id = "kavita_recent",
    label = _("Kavita 最近阅读"),
    icon = "menu_book",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 读取网格行数；非法值回退到两行。
---@return number
function M.rows()
    local n = math.floor(tonumber(MoonSettings.get("home").home_kavita_recent_rows) or DEFAULT_ROWS)
    if n == MIN_ROWS then return MIN_ROWS end
    return MAX_ROWS
end

--- 规范化并保存网格行数。
---@param n number|nil
function M.saveRows(n)
    n = math.floor(tonumber(n) or DEFAULT_ROWS)
    if n ~= MIN_ROWS then n = MAX_ROWS end
    local home = MoonSettings.get("home")
    home.home_kavita_recent_rows = n
    MoonSettings.saveSection("home", home)
end

--- 读取网格列数；夹到 3–8。
---@return number
function M.cols()
    local n = math.floor(tonumber(MoonSettings.get("home").home_kavita_recent_cols) or DEFAULT_COLS)
    return math.max(MIN_COLS, math.min(MAX_COLS, n))
end

--- 规范化并保存网格列数。
---@param n number|nil
function M.saveCols(n)
    n = math.max(MIN_COLS, math.min(MAX_COLS, math.floor(tonumber(n) or DEFAULT_COLS)))
    local home = MoonSettings.get("home")
    home.home_kavita_recent_cols = n
    MoonSettings.saveSection("home", home)
end

--- 读取封面下是否显示书名；缺省视为显示。
---@return boolean
function M.showTitle()
    return MoonSettings.get("home").home_kavita_recent_show_title ~= false
end

--- 规范化并保存封面下是否显示书名。
---@param on boolean|nil
function M.saveShowTitle(on)
    local home = MoonSettings.get("home")
    home.home_kavita_recent_show_title = on ~= false
    MoonSettings.saveSection("home", home)
end

--- 编辑态设置：行数 1/2，列数 3–8，封面下标题开关。
---@param desktop table|nil
function M:showSettings(desktop)
    desktop = desktop or self.desktop or (self.home and self.home.desktop)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    --- 保存后走首页刷新，列数变化时高度不变也必须重建网格。
    local function refresh()
        if desktop and desktop.onEvent then desktop:onEvent("home_refresh") end
    end
    --- 选定行数；与当前相同则只关对话框。
    ---@param n number
    local function pickRows(n)
        UIManager:close(dialog)
        if M.rows() == n then return end
        M.saveRows(n)
        refresh()
    end
    local rows = M.rows()
    dialog = ButtonDialog:new{
        title = M.label,
        buttons = {
            {
                {
                    text = rows == MIN_ROWS and _("✓ 一行") or _("一行"),
                    callback = function() pickRows(MIN_ROWS) end,
                },
                {
                    text = rows == MAX_ROWS and _("✓ 两行") or _("两行"),
                    callback = function() pickRows(MAX_ROWS) end,
                },
            },
            {{
                text = T(_("每行 %1 本"), M.cols()),
                callback = function()
                    UIManager:close(dialog)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("每行数量"),
                        value = M.cols(),
                        value_min = MIN_COLS,
                        value_max = MAX_COLS,
                        value_step = 1,
                        default_value = DEFAULT_COLS,
                        ok_always_enabled = true,
                        callback = function(spin)
                            M.saveCols(spin.value)
                            refresh()
                        end,
                    })
                end,
            }},
            {{
                text = M.showTitle() and _("✓ 显示标题") or _("显示标题"),
                callback = function()
                    UIManager:close(dialog)
                    M.saveShowTitle(not M.showTitle())
                    refresh()
                end,
            }},
            {{
                text = _("关闭"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- 封面下方标题与间隔高度；关闭标题时为 0。
---@return number
local function titleExtra()
    if not M.showTitle() then return 0 end
    return CoverCell.titleExtra()
end

--- 按用户列数算封面；固定列时 denseCoverMetrics 不加列压高，此处封顶；
--- area_h 有值时行×列收到分配高度内，避免页溢出缩放后画出屏幕 BB。
---@param width number 目标宽度，单位像素
---@param area_h number|nil 网格可用高度，单位像素
---@return number slot_w
---@return number cw
---@return number ch
---@return number cols
---@return number gap
---@return number row_gap
---@return number cell_h
local function gridMetrics(width, area_h)
    local cols = M.cols()
    local extra = titleExtra()
    local max_h = M.rows() == 1 and math.huge or UI.gridCoverMaxH(area_h)
    local slot_w, cw, ch, _, gap, row_gap, cell_h = UI.denseCoverMetrics(
        math.max(1, math.floor(tonumber(width) or 1)), 0, {
        title_extra = extra,
        max_h = max_h,
        min_cols = cols,
        max_cols = cols,
    })
    if ch > max_h then
        ch = max_h
        cw = math.max(1, math.min(slot_w, math.floor(ch * 2 / 3)))
        cell_h = ch + extra
    end
    area_h = math.floor(tonumber(area_h) or 0)
    local rows = M.rows()
    if area_h > 0 and rows > 1 then
        local gaps = row_gap * math.max(0, rows - 1)
        local need = cell_h * rows + gaps
        if need > area_h then
            local fit_cell = math.max(1, math.floor((area_h - gaps) / rows))
            ch = math.max(1, math.min(ch, fit_cell - extra))
            cw = math.max(1, math.min(slot_w, math.floor(ch * 2 / 3)))
            cell_h = math.min(ch + extra, fit_cell)
        end
    end
    return slot_w, cw, ch, cols, gap, row_gap, cell_h
end

--- 按所选行列计算内容高度。
---@param _ctx table 为保持组件接口一致保留的上下文，本实现不读取
---@param opts table 布局尺寸、样式及行为选项
---@return table
function M:heightRange(_ctx, opts)
    local _slot_w, _cw, _ch, _cols, _gap, row_gap, cell_h = gridMetrics(opts.width)
    local h = UI.sz(22) + PageStrip.bandH() + cell_h + (M.rows() - 1) * (row_gap + cell_h)
    return { height = h }
end

--- 按当前分页选取书籍并组装封面网格，返回布局和分页信息。
---@param ctx BookDesktopCtx 构建上下文
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
    local rows = M.rows()
    local page_size = math.max(1, cols * rows)
    local pages = math.max(1, math.ceil(#books / page_size))
    page = PageStrip.clamp(page, pages)
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
        table.insert(grid, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            row,
        })
        used = used + cell_h
        row = HorizontalGroup:new{}
        col = 0
    end

    for i = first, last do
        if col > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, (CoverCell.build(ctx, books[i], slot_w, cw, ch, on_open, true, M.showTitle())))
        col = col + 1
        if col == cols then flushRow() end
    end
    if col > 0 then flushRow() end
    return grid, used, page, pages
end

--- 切换网格页码并重建内容区域。
---@param self BookHomeKavitaRecent 当前视图或布局实例
---@param page number 当前页码，从 1 开始
local function turn(self, page)
    self.page = page
    if not self.ctx then return end
    self:rebuild()
end

--- 根据可用空间组装封面网格和分页条，保存当前内容树。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local h = opts.height
    local books = type(self.data) == "table" and self.data or {}
    local section_h = UI.sz(22)
    local band_h = PageStrip.bandH()
    local grid_h = math.max(1, h - section_h - band_h)
    local current = self.page or 1
    local page, pages = 1, 1
    local content
    local content_h = 0

    if #books > 0 then
        content, content_h, page, pages = buildGrid(
            ctx, books, w, grid_h, current, CoverCell.opener(self, ctx)
        )
    else
        content_h = grid_h
        -- 关书回首页会重建桌面，On Deck 未到达前数据为 nil：用加载态，
        -- 别误报「没有在读的书」；data 为空表才是真的服务端没有最近阅读。
        local text = self.error or (self.data == nil and _("加载中…") or _("没有在读的书"))
        content = CenterContainer:new{
            dimen = Geom:new{ w = w, h = grid_h },
            TextWidget:new{
                text = text,
                face = UI.face("xx_smallinfofont", 12),
                fgcolor = UI.muted(),
            },
        }
    end
    self.page = page

    local label = #books > 0 and T(_("Kavita 最近阅读 · %1"), #books) or _("Kavita 最近阅读")
    local kids = {
        align = "left",
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = section_h },
            FrameContainer:new{
                bordersize = 0,
                padding = 0,
                padding_bottom = UI.sz(4),
                margin = 0,
                TextWidget:new{
                    text = label,
                    face = UI.face("cfont", 12),
                    bold = true,
                    fgcolor = UI.muted(),
                },
            },
        },
        content,
    }
    local filler = math.max(0, grid_h - content_h)
    if filler > 0 then kids[#kids + 1] = VerticalSpan:new{ width = filler } end
    kids[#kids + 1] = PageStrip.widget{
        width = w,
        page = page,
        pages = pages,
        on_prev = function() turn(self, page - 1) end,
        on_next = function() turn(self, page + 1) end,
    }

    local inner = VerticalGroup:new(kids)
    self.content_widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = h },
        inner,
    }
    self.ctx = ctx
    self.opts = opts
    self.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = h }
    return self.content_widget
end

--- 从 Kavita 服务器拉最近阅读（On Deck）；失败时保留旧数据。
---@param done fun(data:any, err:any)
---@return table|nil
function M:loadData(done)
    local source, err = require("source.registry").resolve("kavita")
    if not source then
        done(nil, err or _("数据源不可用"))
        return nil
    end
    if type(source.onDeckAsync) ~= "function" then
        done(nil, _("数据源不可用"))
        return nil
    end
    return source:onDeckAsync(function(books, on_deck_err)
        done(books, on_deck_err)
    end)
end

--- 转交组件事件给首页基类；换源时重置页码。
---@param event string|table 从父视图转发的事件标识或事件对象
function M:onEvent(event)
    if event == "source_changed" then self.page = nil end
    require("ui.desktop.home.views.base").onEvent(self, event)
end

--- 恢复显示时拉取服务端数据，数据到达后重建网格。
function M:onResume()
    if not self.lifecycle:uiReady() then return end
    self:load(function(ok, err)
        self.error = ok and nil or err
        if self.widget then self:rebuild() end
    end)
end

--- 向当前内容树发送 HomePause，取消封面请求后清除内容引用。
function M:onPause()
    if self.content_widget then
        self.content_widget:handleEvent(Event:new("HomePause"))
        self.content_widget = nil
    end
    self.region = nil
end

return M
