--[[--
主体：最近阅读列表（长条+网格 或 纯列表）。

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
local MoonSettings = require("utils.settings")
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

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local budget = opts.budget or opts.width
    local pad = UI.sz(10)
    local mode = MoonSettings.get("home").home_recent_list_mode or "hero_grid"
    local list_only = opts.list_only or mode == "list_only"
    local consume = opts.consume_remaining
    local desktop = opts.desktop
    local on_open, on_read = openHandlers(ctx)
    local kids = { align = "left" }
    local used = 0
    local pager = nil
    local reading = state.reading or {}
    local recent = state.recent
    local total = #reading + (recent and 1 or 0)

    if not list_only then
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

    local label
    if list_only then
        label = total > 0 and T(_("最近阅读 · %1"), total) or _("最近阅读")
    else
        label = #reading > 0 and T(_("最近阅读 · %1"), #reading) or _("最近阅读")
    end
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

    if total == 0 then
        local empty_h = list_only and state.recent_err and UI.sz(40) or UI.sz(28)
        local empty_text = list_only and state.recent_err
            and (state.recent_err or _("去图书馆挑一本 ›"))
            or _("没有在读的书")
        local empty_widget
        if list_only and state.recent_err then
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
                        text = empty_text,
                        face = UI.face("cfont", 14),
                        fgcolor = UI.muted(),
                    },
                },
            }
            empty_widget = tap
        else
            empty_widget = LeftContainer:new{
                dimen = Geom:new{ w = w, h = empty_h },
                FrameContainer:new{
                    bordersize = 0,
                    padding = pad,
                    margin = 0,
                    TextWidget:new{
                        text = empty_text,
                        face = UI.face("xx_smallinfofont", 12),
                        fgcolor = UI.muted(),
                    },
                },
            }
        end
        table.insert(kids, empty_widget)
        used = used + empty_h
    else
        local grid_books = reading
        if list_only then
            grid_books = {}
            if recent then table.insert(grid_books, recent) end
            for i, book in ipairs(reading) do
                table.insert(grid_books, book)
            end
        end
        local band_h = consume and Pager.bandH() or 0
        local grid_budget = math.max(UI.sz(80), budget - band_h - used)
        if not consume and not list_only then
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
