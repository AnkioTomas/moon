--[[--
主体：最近阅读列表（长条+网格 或 纯列表）。

@module koplugin.book.ui.desktop.home.components.recent_list
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local MoonSettings = require("utils.settings")
local Pager = require("ui.components.pager")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local U = require("lockscreen.components.util")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "recent_list",
    label = _("最近阅读列表"),
}

local function openLibrary(desktop)
    if not desktop or not desktop.switchTab then return end
    desktop.filter = {}
    desktop.page = 1
    desktop._library_state = nil
    desktop:switchTab("library")
end

local function openHandlers(ctx)
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end
    local on_read = function(book)
        local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
        if plugin and plugin.openBook then
            plugin:openBook(book)
        else
            on_open(book)
        end
    end
    return on_open, on_read
end

local function coverCell(ctx, book, slot_w, cw, ch, on_open)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = true,
        show_parent = ctx.desktop,
    }))
    local tap = BookInfo.tappable(slot_w, ch, function()
        if on_open then on_open(book) end
    end)
    tap[1] = LeftContainer:new{
        dimen = Geom:new{ w = slot_w, h = ch },
        cover,
    }
    return tap, ch
end

local function buildGrid(ctx, books, w, pad, budget_h, page, on_open)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, cgap, row_gap = UI.denseCoverMetrics(avail, budget_h)
    local rows = math.max(1, math.floor((budget_h + row_gap) / (ch + row_gap)))
    local page_size = math.max(1, cols * rows)
    local pages = math.max(1, math.ceil(#books / page_size))
    page = Pager.clamp(page, pages)
    local start_i = (page - 1) * page_size + 1
    local stop_i = math.min(#books, start_i + page_size - 1)

    local grid = VerticalGroup:new{ align = "left" }
    local row_group = HorizontalGroup:new{}
    local col_i = 0
    local row_n = 0
    local grid_h = 0

    local function flushRow()
        if row_n > 0 then
            table.insert(grid, VerticalSpan:new{ width = row_gap })
            grid_h = grid_h + row_gap
        end
        table.insert(grid, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad,
            padding_right = pad,
            margin = 0,
            row_group,
        })
        grid_h = grid_h + ch
        row_group = HorizontalGroup:new{}
        col_i = 0
        row_n = row_n + 1
    end

    for i = start_i, stop_i do
        local cell = coverCell(ctx, books[i], slot_w, cw, ch, on_open)
        if col_i > 0 then
            table.insert(row_group, HorizontalSpan:new{ width = cgap })
        end
        table.insert(row_group, cell)
        col_i = col_i + 1
        if col_i >= cols then
            flushRow()
        end
    end
    if col_i > 0 then
        flushRow()
    end
    return grid, grid_h, page, pages
end

local function listRow(ctx, book, w, pad, on_open)
    local gap = UI.sz(8)
    local cw = UI.sz(36)
    local ch = math.floor(cw * 3 / 2)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = false,
        show_parent = ctx.desktop,
    }))
    local info_w = math.max(UI.sz(40), w - pad * 2 - cw - gap)
    local title_w = TextWidget:new{
        text = BookInfo.title(book),
        face = UI.face("cfont", 14),
        max_width = info_w,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local author = BookInfo.author(book)
    local chapter = U.chapterLine(book)
    local meta = author ~= "" and author or _("未知作者")
    if chapter ~= "" then
        meta = meta .. " · " .. chapter
    end
    local meta_w = TextWidget:new{
        text = meta,
        face = UI.face("xx_smallinfofont", 11),
        max_width = info_w,
        fgcolor = UI.muted(),
    }
    local pct = BookInfo.pct(book)
    local pct_w = TextWidget:new{
        text = string.format("%.0f%%", pct),
        face = UI.face("xx_smallinfofont", 11),
        max_width = info_w,
        fgcolor = UI.dim(),
    }
    local row_h = math.max(ch, title_w:getSize().h + meta_w:getSize().h + pct_w:getSize().h + UI.sz(4))
    local info = VerticalGroup:new{
        align = "left",
        title_w,
        VerticalSpan:new{ width = UI.sz(2) },
        meta_w,
        VerticalSpan:new{ width = UI.sz(2) },
        pct_w,
    }
    local row = HorizontalGroup:new{
        CenterContainer:new{ dimen = Geom:new{ w = cw, h = row_h }, cover },
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{ dimen = Geom:new{ w = info_w, h = row_h }, info },
    }
    local tap = BookInfo.tappable(w, row_h + UI.sz(6), function()
        if on_open then on_open(book) end
    end)
    tap[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        margin = 0,
        row,
    }
    return tap, row_h + UI.sz(6)
end

local function buildList(ctx, books, w, pad, budget_h, max_rows, on_open)
    local group = VerticalGroup:new{ align = "left" }
    local used = 0
    local count = math.min(#books, max_rows or 8)
    for i = 1, count do
        local row, rh = listRow(ctx, books[i], w, pad, on_open)
        if used + rh > budget_h then break end
        table.insert(group, row)
        used = used + rh
    end
    return group, used
end

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local budget = opts.budget or opts.width
    local pad = UI.sz(10)
    local mode = MoonSettings.get("home").home_recent_list_mode or "hero_grid"
    local list_only = mode == "list_only"
    local consume = opts.consume_remaining
    local desktop = opts.desktop
    local on_open, on_read = openHandlers(ctx)
    local kids = { align = "left" }
    local used = 0
    local pager = nil

    local all_books = {}
    if state.recent then table.insert(all_books, state.recent) end
    for i, book in ipairs(state.reading or {}) do
        table.insert(all_books, book)
    end

    if not list_only then
        local recent = state.recent
        if recent then
            local row, rh = BookInfo.hero(ctx.plugin, ctx.source, recent, {
                width = w,
                pad = pad,
                show_parent = ctx.desktop,
                on_tap = function() on_read(recent) end,
            })
            table.insert(kids, row)
            used = used + rh
        else
            local empty_h = UI.sz(40)
            local tap = BookInfo.tappable(w, empty_h, function()
                openLibrary(ctx.desktop)
            end)
            tap[1] = LeftContainer:new{
                dimen = Geom:new{ w = w, h = empty_h },
                FrameContainer:new{
                    bordersize = 0,
                    padding = pad,
                    margin = 0,
                    TextWidget:new{
                        text = state.recent_err or _("去图书馆挑一本 ›"),
                        face = UI.face("cfont", 14),
                        fgcolor = UI.muted(),
                    },
                },
            }
            table.insert(kids, tap)
            used = used + empty_h
        end
        local gap = UI.sz(8)
        table.insert(kids, VerticalSpan:new{ width = gap })
        used = used + gap
    end

    local reading = state.reading or {}
    local grid_books = list_only and all_books or reading
    local label = #grid_books > 0 and T(_("最近阅读 · %1"), #grid_books) or _("最近阅读")
    local section_h = UI.sz(22)
    table.insert(kids, LeftContainer:new{
        dimen = Geom:new{ w = w, h = section_h },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad,
            padding_bottom = UI.sz(4),
            margin = 0,
            TextWidget:new{
                text = label,
                face = UI.face("cfont", 12),
                bold = true,
                fgcolor = UI.muted(),
            },
        },
    })
    used = used + section_h

    if #grid_books == 0 then
        local empty_msg = UI.sz(28)
        table.insert(kids, LeftContainer:new{
            dimen = Geom:new{ w = w, h = empty_msg },
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                margin = 0,
                TextWidget:new{
                    text = _("没有在读的书"),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = UI.muted(),
                },
            },
        })
        used = used + empty_msg
    elseif list_only then
        local remaining = budget - used
        local list, list_h = buildList(ctx, grid_books, w, pad, remaining, consume and 99 or 6, on_open)
        table.insert(kids, list)
        used = used + list_h
    else
        local band_h = consume and Pager.bandH() or 0
        local grid_budget = math.max(UI.sz(80), budget - band_h - used)
        if not consume then
            grid_budget = math.min(grid_budget, UI.sz(160))
        end
        local cur = (desktop and desktop._home_reading_page) or 1
        local grid, grid_h, page, pages = buildGrid(ctx, grid_books, w, pad, grid_budget, cur, on_open)
        if desktop then desktop._home_reading_page = page end
        table.insert(kids, grid)
        used = used + grid_h
        if consume and pages > 0 then
            pager = {
                page = page,
                pages = pages,
                handlers = {
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
                },
            }
        end
    end

    local widget = VerticalGroup:new(kids)
    return { widget = widget, height = used, pager = pager }
end

return M
