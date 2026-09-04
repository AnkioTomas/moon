--[[--
主体：最近阅读书架。

@module koplugin.book.ui.desktop.home.components.recent_list
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Pager = require("ui.components.pager")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "recent_list",
    label = _("最近阅读列表"),
    icon = "view_list",
}

local function titleExtra()
    return UI.sz(4) + UI.sz(22)
end

---@param width number
---@param area_h number|nil
---@return number slot_w
---@return number cw
---@return number ch
---@return number cols
---@return number gap
---@return number row_gap
---@return number cell_h
local function gridMetrics(width, area_h)
    local pad = UI.sz(10)
    return UI.denseCoverMetrics(math.max(1, width - pad * 2), 0, {
        title_extra = titleExtra(),
        max_h = UI.gridCoverMaxH(area_h),
    })
end

---@param _ctx table
---@param _state table
---@param opts table
---@return table
function M.heightRange(_ctx, _state, opts)
    local _, _, _, _, _, row_gap, cell_h = gridMetrics(opts.width)
    local fixed = UI.sz(22) + Pager.bandH()
    local one_row = fixed + cell_h
    return {
        min = one_row,
        preferred = one_row + row_gap + cell_h,
        max = one_row + (row_gap + cell_h) * 2,
        grow = 6,
        step = row_gap + cell_h,
    }
end

---@param ctx table
---@param book Book
---@param slot_w number
---@param cw number
---@param ch number
---@param on_open fun(book: Book)
---@return table
local function coverCell(ctx, book, slot_w, cw, ch, on_open)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = true,
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

---@param ctx table
---@param books Book[]
---@param width number
---@param grid_h number
---@param page number
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
    page = Pager.clamp(page, pages)
    local first = (page - 1) * page_size + 1
    local last = math.min(#books, first + page_size - 1)
    local grid = VerticalGroup:new{ align = "left" }
    local row = HorizontalGroup:new{}
    local col = 0
    local row_count = 0
    local used = 0

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

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local h = opts.height
    local desktop = opts.desktop
    local books = state.reading or {}
    local section_h = UI.sz(22)
    local band_h = Pager.bandH()
    local grid_h = math.max(1, h - section_h - band_h)
    local current = (desktop and desktop._home_reading_page) or 1
    local page, pages = 1, 1
    local content
    local content_h = 0

    local function onOpen(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
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
    if desktop then desktop._home_reading_page = page end

    local handlers = {
        on_prev = function()
            if desktop then desktop._home_reading_page = page - 1 desktop:rebuild() end
        end,
        on_next = function()
            if desktop then desktop._home_reading_page = page + 1 desktop:rebuild() end
        end,
        on_first = function()
            if desktop then desktop._home_reading_page = 1 desktop:rebuild() end
        end,
        on_last = function()
            if desktop then desktop._home_reading_page = pages desktop:rebuild() end
        end,
    }
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
    kids[#kids + 1] = Pager.band(w, page, pages, handlers)

    return {
        widget = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new(kids),
        },
        height = h,
    }
end

return M
