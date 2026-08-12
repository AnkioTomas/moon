--[[--
主页：英雄卡 + 封面网格（仅封面+进度角标）
  左右等边距；行距略松，避免封面上下挤在一起。

@module koplugin.book.ui.home
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local Pager = require("ui.components.pager")
local Cache = require("moon.cache")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Home = {}

local function isFinished(book)
    local f = book.finished
    return f == true or f == 1 or f == "1"
end

local function openLibrary(desktop)
    if not desktop or not desktop.switchTab then return end
    desktop.filter = {}
    desktop.page = 1
    desktop._library_state = nil
    desktop:switchTab("library")
end

--- 封面-only 格子（参考图无题下文字）
local function coverCell(ctx, book, slot_w, cw, ch, on_open)
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, { badge = true }))
    local tap = BookInfo.tappable(slot_w, ch, function()
        if on_open then on_open(book) end
    end)
    tap[1] = LeftContainer:new{
        dimen = Geom:new{ w = slot_w, h = ch },
        cover,
    }
    return tap, ch
end

--- 网格尺度：默认 4 列；横向紧凑、纵向留白
local function denseMetrics(avail_w, budget_h)
    local gap = UI.sz(8)
    local cols = 4
    local function slotFor(c)
        return math.floor((avail_w - gap * (c - 1)) / c)
    end
    local slot_w = slotFor(cols)
    if slot_w < UI.sz(52) then
        cols = 3
        slot_w = slotFor(cols)
    end
    local cw = slot_w
    local ch = math.floor(cw * 3 / 2)
    -- 行距明显大于列距，封面上下不贴死
    local row_gap = UI.sz(14)
    if budget_h > 0 and ch * 2 + row_gap > budget_h then
        local fit = math.floor((budget_h - row_gap) / 2)
        if fit >= UI.sz(64) then
            ch = fit
            cw = math.max(1, math.floor(ch * 2 / 3))
            if cw > slot_w then
                cw = slot_w
                ch = math.floor(cw * 3 / 2)
            end
        end
    end
    return slot_w, cw, ch, cols, gap, row_gap
end

local function buildGrid(ctx, books, w, pad, budget_h, page, on_open)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, cgap, row_gap = denseMetrics(avail, budget_h)
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

    -- FrameContainer 的 dimen.h 不参与 getSize；行距必须用 padding / Span
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

function Home.build(ctx, state)
    local w = ctx.width
    local h = ctx.height
    local pad = UI.sz(10)
    local band_h = Pager.bandH()
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

    local kids = { align = "left" }
    local used = 0

    local recent = state.recent
    if recent then
        local row, rh = BookInfo.hero(ctx.plugin, ctx.source, recent, {
            width = w,
            pad = pad,
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

    local reading = state.reading or {}
    local label = #reading > 0 and T(_("最近阅读 · %1"), #reading) or _("最近阅读")
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

    local desktop = ctx.desktop
    local handlers = {}
    local page, pages = 1, 1

    if #reading == 0 then
        table.insert(kids, LeftContainer:new{
            dimen = Geom:new{ w = w, h = UI.sz(28) },
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
        used = used + UI.sz(28)
    else
        local budget = math.max(UI.sz(80), h - band_h - used)
        local cur = (desktop and desktop._home_reading_page) or 1
        local grid, grid_h, p, ps = buildGrid(ctx, reading, w, pad, budget, cur, on_open)
        page, pages = p, ps
        if desktop then desktop._home_reading_page = page end
        table.insert(kids, grid)
        used = used + grid_h
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
        }
    end

    -- 内容顶对齐；余量留给底部分页条，不再在网格下方留一大块空 body
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

function Home.fetch(desktop)
    if desktop._home_fetching then return end
    desktop._home_fetching = true

    if desktop._home_fetch_cancel then
        desktop._home_fetch_cancel()
        desktop._home_fetch_cancel = nil
    end

    if not desktop._local_cleanup_done then
        desktop._local_cleanup_done = true
        UIManager:scheduleIn(0.3, function()
            if desktop._closed then return end
            local ok, n = pcall(Cache.cleanupStale)
            if ok and n and n > 0 then
                logger.info("book cleaned stale local books:", n)
            elseif not ok then
                logger.warn("book local cleanup failed", n)
            end
        end)
    end

    local source = desktop.source
    if not desktop._home_loaded then
        desktop._home_state = { recent_err = _("加载中…"), reading = {} }
        desktop._home_loaded = true
        if not desktop._closed and desktop.tab == "home" then
            desktop:rebuild()
        end
    end

    local function finish(state)
        desktop._home_fetching = false
        desktop._home_fetch_cancel = nil
        desktop._home_state = state or {}
        desktop._home_loaded = true
        if desktop._closed or desktop.tab ~= "home" then return end
        desktop:rebuild()
    end

    local Async = require("moon.async")
    desktop._home_fetch_cancel = Async.run(function()
        if not source or not source.configured or not source:configured() then
            return nil, _("请先配置数据源")
        end
        return source:recentBooks(24)
    end, function(ok, res, err)
        if desktop._closed then
            desktop._home_fetching = false
            desktop._home_fetch_cancel = nil
            return
        end
        if not ok then
            finish({ recent_err = err or _("加载失败"), reading = {} })
            return
        end
        local applied, boom = pcall(function()
            if not res then
                finish({
                    recent = nil,
                    recent_err = err or _("加载失败"),
                    reading = {},
                })
                return
            end
            local rows = res.data or {}
            local recent = rows[1]
            local skip = recent and BookInfo.file(recent)
            local reading = {}
            for _, book in ipairs(rows) do
                if BookInfo.file(book) ~= skip and not isFinished(book) and BookInfo.pct(book) > 0 then
                    table.insert(reading, book)
                end
            end
            Cache.rememberMany(rows)
            if source.primeRecentCache then
                source:primeRecentCache(24, res)
            end
            finish({ recent = recent, reading = reading })
        end)
        if not applied then
            logger.err("book home fetch apply failed:", boom)
            finish({ recent_err = tostring(boom), reading = {} })
        end
    end)
end

function Home.page(desktop)
    local h = desktop:contentHeight()
    local w = (desktop.dimen and desktop.dimen.w) or Screen:getWidth()
    if not desktop._home_loaded then
        UIManager:nextTick(function()
            if desktop._closed or desktop.tab ~= "home" then return end
            Home.fetch(desktop)
        end)
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                TextWidget:new{
                    text = _("加载主页…"),
                    face = UI.face("cfont", 18),
                    fgcolor = UI.muted(),
                },
            },
        }
    end
    return Home.build(desktop:ctx(), desktop._home_state or {})
end

return Home
