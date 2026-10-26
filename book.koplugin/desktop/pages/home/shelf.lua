--[[--
主体：书架。按图书馆当前排序列出在架书封面，点封面开书，标题行「更多 ›」进图书馆。
行数可选一行 / 两到四行 / 自动（按分配高度能放几行放几行，配合编辑页的「填满」）；
只查放得下的那几本（LIMIT 行×列），不读整库。

@module koplugin.book.desktop.pages.home.shelf
--]]

local Book = require("ui.widgets.book")
local CoverCell = require("ui.widgets.cover")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local MoonSettings = require("utils.settings")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

local MAX_ROWS, DEFAULT_ROWS = 4, 1
local MIN_COLS, MAX_COLS, DEFAULT_COLS = 3, 8, 4

---@class BookHomeShelf : BookHomeComponent
local M = {
    id = "shelf",
    label = _("书架"),
    icon = "shelves",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

local function home() return MoonSettings.get("desktop.pages.home") end

local function save(key, value)
    local h = home()
    h[key] = value
    MoonSettings.save("desktop.pages.home", h)
end

--- 行数：1–4；0 为自动（按分配高度）。
---@return integer
function M.rows()
    local n = math.floor(tonumber(home().home_shelf_rows) or DEFAULT_ROWS)
    return (n >= 0 and n <= MAX_ROWS) and n or DEFAULT_ROWS
end

---@return integer
function M.cols()
    local n = math.floor(tonumber(home().home_shelf_cols) or DEFAULT_COLS)
    return math.max(MIN_COLS, math.min(MAX_COLS, n))
end

--- 编辑态设置：单行 / 多行（2–4 行或自动），每行本数。
---@param desktop BookDesktop
function M:showSettings(desktop)
    local rows = M.rows()
    local function pick(n)
        if M.rows() == n then return end
        save("home_shelf_rows", n)
        desktop:onEvent("home_refresh")
    end
    local function opt(n, label)
        return { text = label, checked = rows == n, callback = function() pick(n) end }
    end
    require("ui.themes.widgets.list"):new{
        title = M.label, centered = true,
        items = {
            opt(1, _("一行")), opt(2, _("两行")), opt(3, _("三行")), opt(4, _("四行")), opt(0, _("自动")),
            { text = T(_("每行 %1 本"), M.cols()), chevron = true, callback = function()
                require("ui.themes.widgets.spin"):new{
                    title = _("每行数量"),
                    fields = { { value = M.cols(), min = MIN_COLS, max = MAX_COLS } },
                    callback = function(value)
                        save("home_shelf_cols", math.max(MIN_COLS, math.min(MAX_COLS, math.floor(tonumber(value) or DEFAULT_COLS))))
                        desktop:onEvent("home_refresh")
                    end,
                }:show()
            end },
        },
    }:show()
end

--- 固定列数下的单元格度量（宽度决定封面，封顶到网格封面高度上限）。
---@param width number
---@return number slot_w, number cw, number ch, number gap, number row_gap, number cell_h
local function metrics(width)
    local cols = M.cols()
    local lib = CoverCell.libraryConf()
    local extra = Book.captionExtra(true, lib.author, lib.kobo)
    local max_h = CoverCell.gridCoverMaxH()
    local slot_w, cw, ch, _cols, gap, row_gap, cell_h = CoverCell.denseCoverMetrics(math.max(1, width), 0, {
        title_extra = extra, max_h = max_h, min_cols = cols, max_cols = cols,
    })
    if ch > max_h then
        ch = max_h
        cw = CoverCell.stretchW(slot_w, math.max(1, math.min(slot_w, math.floor(ch * 2 / 3))), ch)
        cell_h = ch + extra
    end
    return slot_w, cw, ch, gap, row_gap, cell_h
end

local function headerHeight()
    return Text.line("caption", "0"):getSize().h + Theme.px(Theme.current().space.xs)
end

--- 自动行数默认按两行给内容高度，编辑页设成「填满」时再按分配高度多放。
---@return BookHomeHeightSpec
function M:heightRange(_ctx, opts)
    local _sw, _cw, _ch, _gap, row_gap, cell_h = metrics(opts.width)
    local rows = M.rows() == 0 and 2 or M.rows()
    return { height = headerHeight() + cell_h * rows + row_gap * (rows - 1) }
end

--- 按图书馆当前排序取前 n 本在架书。
---@param ctx table
---@param n integer
---@return Book[] books, integer|nil count
function M.books(ctx, n)
    local Catalog = require("book.catalog")
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    local scope = Catalog.libraryScope(source and source.id)
    if not (type(scope) == "string" and scope ~= "" or type(scope) == "table" and #scope > 0) then return {} end
    local library = ctx.desktop and ctx.desktop.library
    local sort = library and library.sort or MoonSettings.get("desktop").library_sort
    local rows, count = Catalog.listBooks(scope, { sort = sort, limit = n })
    return Catalog.toList(rows, count, type(scope) == "string" and scope or nil).data, count
end

---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local t = Theme.current()
    local w, h = opts.width, opts.height
    local slot_w, cw, ch, gap, row_gap, cell_h = metrics(w)
    local grid_h = math.max(1, h - headerHeight())
    local fit = math.max(1, math.floor((grid_h + row_gap) / (cell_h + row_gap)))
    local rows = M.rows() == 0 and fit or math.min(M.rows(), fit)
    local cols = M.cols()
    local books, count = M.books(ctx, rows * cols)
    local body
    if #books > 0 then
        ctx.on_detail = function(book) require("desktop.detail").open(ctx.desktop, "library", book) end
        local on_open = CoverCell.opener(self, ctx, require("desktop.open").book)
        body = VerticalGroup:new{ align = "left" }
        local lib = CoverCell.libraryConf()
        for r = 1, math.ceil(#books / cols) do
            if r > 1 then body[#body + 1] = VerticalSpan:new{ width = row_gap } end
            local row = HorizontalGroup:new{}
            for c = 1, cols do
                local book = books[(r - 1) * cols + c]
                if not book then break end
                if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                row[#row + 1] = (CoverCell.build(ctx, book, slot_w, cw, ch, on_open, true, true, lib.author, lib))
            end
            body[#body + 1] = row
        end
    else
        body = CenterContainer:new{
            dimen = Geom:new{ w = w, h = grid_h },
            Text.line("caption", _("没有书籍"), { color = t.color.muted }),
        }
    end
    local more = Tap.wrap(Text.line("caption", _("更多 ›"), { color = t.color.muted }), function()
        local desktop = ctx.desktop
        if not desktop then return end
        desktop.library:reset()
        desktop:switchTab("library")
    end)
    local more_size = more:getSize()
    local label_w = math.max(1, w - more_size.w)
    -- TextWidget 的 width 只是上限：外包定宽容器，「更多 ›」才能靠右。
    local label = LeftContainer:new{
        dimen = Geom:new{ w = label_w, h = more_size.h },
        Text.line("caption", (count or 0) > 0 and T(_("书架 · %1"), count) or _("书架"),
            { width = label_w, color = t.color.muted, bold = true }),
    }
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{ align = "center", label, more },
        VerticalSpan:new{ width = Theme.px(t.space.xs) },
        body,
    }
end

return M
