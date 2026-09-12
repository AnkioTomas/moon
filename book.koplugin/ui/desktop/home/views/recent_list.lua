--[[--
主体：最近阅读书架。

@module koplugin.book.ui.desktop.home.views.recent_list
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local Catalog = require("book.catalog")
local Event = require("ui/event")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local PageStrip = require("ui.components.pagestrip")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookHomeRecentList : BookHomeComponent
local M = {
    id = "recent_list",
    label = _("最近阅读列表"),
    icon = "view_list",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M



--- 返回最近阅读网格封面下方的标题和间隔高度。
---@return number height 封面下方标题与间隔高度，单位像素
local function titleExtra()
    return UI.sz(4) + UI.sz(22)
end

--- 根据网格宽度和可用高度计算封面尺寸、列数及行间距。
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
    local pad = UI.sz(10)
    -- budget 传 0：两行压缩会把「只够一行」的高度误判成「压矮封面塞两行」。
    return UI.denseCoverMetrics(math.max(1, width - pad * 2), 0, {
        title_extra = titleExtra(),
        max_h = UI.gridCoverMaxH(area_h),
    })
end

--- 返回当前组件的最小、首选和最大高度，供首页布局分配空间。
---@param _ctx table 为保持组件接口一致保留的上下文，本实现不读取
---@param opts table 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table
function M:heightRange(_ctx, opts)
    local _slot_w, _cw, _ch, _cols, _gap, row_gap, cell_h = gridMetrics(opts.width)
    local fixed = UI.sz(22) + PageStrip.bandH()
    local one_row = fixed + cell_h
    return {
        min = one_row,
        preferred = one_row + row_gap + cell_h,
        max = one_row + (row_gap + cell_h) * 2,
        grow = 6,
        step = row_gap + cell_h,
    }
end

--- 构建带书籍状态标记的网格封面和标题，点击时打开对应书籍。
---@param ctx BookDesktopCtx 构建上下文，提供尺寸、数据源和桌面宿主
---@param book Book 当前操作或展示的书籍数据
---@param slot_w number 单个封面槽位宽度，单位像素
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@param on_open fun(book: Book)
---@return table
local function coverCell(ctx, book, slot_w, cw, ch, on_open)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = true,
        ribbon = true,
        download = true,
        show_parent = ctx.desktop,
    }))
    local tap = BookInfo.tappable(slot_w, ch + titleExtra(), function()
        on_open(book)
    end)
    tap[1] = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = ch },
            cover,
        },
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = BookInfo.title(book),
            face = UI.face("xx_smallinfofont", 13),
            max_width = slot_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap
end

--- 按当前分页选取书籍并组装封面网格，返回布局和分页信息。
---@param ctx BookDesktopCtx 构建上下文，提供尺寸、数据源和桌面宿主
---@param books Book[] 按展示顺序排列的书籍列表
---@param width number 目标宽度，单位像素
---@param grid_h number 网格区域高度，单位像素
---@param page number 当前页码，从 1 开始
---@param on_open fun(book: Book)
---@return table
---@return number
---@return number
---@return number
local function buildGrid(ctx, books, width, grid_h, page, on_open)
    local pad = UI.sz(10)
    local slot_w, cw, ch, cols, gap, row_gap, cell_h = gridMetrics(width, grid_h)
    local rows = math.max(1, math.floor((grid_h + row_gap) / (cell_h + row_gap)))
    local page_size = math.max(1, cols * rows)
    local pages = math.max(1, math.ceil(#books / page_size))
    page = PageStrip.clamp(page, pages)
    local first = (page - 1) * page_size + 1
    local last = math.min(#books, first + page_size - 1)
    local grid = VerticalGroup:new{ align = "left" }
    local row = HorizontalGroup:new{}
    local col = 0
    local row_count = 0
    local used = 0

    --- 把当前累计的网格单元打包为一行并清空行缓冲。
    ---@return nil
    local function flushRow()
        if row_count > 0 then
            table.insert(grid, VerticalSpan:new{ width = row_gap })
            used = used + row_gap
        end
        table.insert(grid, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad,
            padding_right = pad,
            margin = 0,
            row,
        })
        used = used + cell_h
        row = HorizontalGroup:new{}
        col = 0
        row_count = row_count + 1
    end

    for i = first, last do
        if col > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, coverCell(ctx, books[i], slot_w, cw, ch, on_open))
        col = col + 1
        if col == cols then flushRow() end
    end
    if col > 0 then flushRow() end
    return grid, used, page, pages
end

--- 切换最近阅读网格页码并重建内容区域。
---@param self BookHomeRecentList 当前视图或布局实例
---@param page number 当前页码，从 1 开始
---@return nil
local function turn(self, page)
    self.page = page
    if not self.ctx then return end
    self:rebuild()
end

--- 根据可用空间组装最近阅读封面网格和分页条，保存当前内容树。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local h = opts.height
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    local _ignored_recent, books = Catalog.recentShelf(source and source.id, 24)
    books = books or {}
    local section_h = UI.sz(22)
    local band_h = PageStrip.bandH()
    local grid_h = math.max(1, h - section_h - band_h)
    local current = self.page or 1
    local page, pages = 1, 1
    local content
    local content_h = 0

    --- 使用当前构建上下文打开所选书籍。
    ---@param book Book 当前操作或展示的书籍数据
    ---@return nil
    local function onOpen(book)
        if ctx.desktop then
            require("ui.desktop.detail").open(ctx.desktop, book)
        end
    end

    if #books > 0 then
        content, content_h, page, pages = buildGrid(
            ctx, books, w, grid_h, current, onOpen
        )
    else
        content_h = grid_h
        content = CenterContainer:new{
            dimen = Geom:new{ w = w, h = grid_h },
            TextWidget:new{
                text = _("没有在读的书"),
                face = UI.face("xx_smallinfofont", 12),
                fgcolor = UI.muted(),
            },
        }
    end
    self.page = page

    local label = #books > 0 and T(_("最近阅读 · %1"), #books) or _("最近阅读")
    local kids = {
        align = "left",
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = section_h },
            FrameContainer:new{
                bordersize = 0,
                padding = 0,
                padding_left = UI.sz(10),
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

--- 转交组件事件给首页基类，由基类处理需要重建的变化。
---@param event string|table 从父视图转发的事件标识或事件对象
---@return nil
function M:onEvent(event)
    if event == "source_changed" then self.page = nil end
end

--- 恢复显示时重建网格内容以同步最近阅读记录。
---@return nil
function M:onResume()
    if self.widget then self:rebuild() end
end

--- 向当前内容树发送 HomePause，取消封面请求后清除内容引用。
---@return nil
function M:onPause()
    if self.content_widget then
        self.content_widget:handleEvent(Event:new("HomePause"))
        self.content_widget = nil
    end
    self.region = nil
end

return M
