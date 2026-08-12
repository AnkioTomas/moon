--[[--
图书馆：封面优先书架
  顶栏：搜索 / 筛选 / 清除 + 右上角总数
  网格：大封面（进度%叠右上角）+ 单行标题
  筛选互斥：同一时刻只应用一个条件（搜索或分类/标签/系列/作者之一）

筛选字段与 /index/book/filters 对齐：
  favorites  → 分类（list 参数 favorite）
  categories → 标签（list 参数 category）
  groupNames → 系列（list 参数 series）
  authors    → 作者（list 参数 author）

@module koplugin.book.ui.library
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("ui.components.cover")
local UI = require("ui.components.bookui")
local Cache = require("moon.cache")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Library = {}

local FILTER_KINDS = {
    favorite = {
        title = _("选择分类"),
        label = _("分类"),
        list_key = "favorites",
        query_key = "favorite",
        aliases = { "favorites" },
    },
    category = {
        title = _("选择标签"),
        label = _("标签"),
        list_key = "categories",
        query_key = "category",
        aliases = { "categories", "tags" },
    },
    series = {
        title = _("选择系列"),
        label = _("系列"),
        list_key = "groupNames",
        query_key = "series",
        aliases = { "groupNames", "series" },
    },
    author = {
        title = _("选择作者"),
        label = _("作者"),
        list_key = "authors",
        query_key = "author",
        aliases = { "authors", "author" },
    },
}

local FILTER_ORDER = { "favorite", "category", "series", "author" }


local function loadIcon(name, size)
    size = size or UI.sz(18)
    local ok, img = pcall(function()
        return ImageWidget:new{
            file = UI.iconDir() .. name,
            width = size,
            height = size,
            alpha = true,
        }
    end)
    if ok and img then
        return img
    end
    return TextWidget:new{
        text = "·",
        face = UI.face("cfont", 14),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

local function bookTitle(book)
    return book.bookName or book.filename or "?"
end

local function tappable(w, h, on_tap)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapLib = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapLib = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

--- 顶栏入口：图标 + 文字，无边框
local function iconAction(icon_name, text, callback)
    local icon_sz = UI.sz(18)
    local label = TextWidget:new{
        text = text,
        face = UI.face("xx_smallinfofont", 15),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local pad_x = UI.sz(8)
    local pad_y = UI.sz(6)
    local gap = UI.sz(4)
    local label_sz = label:getSize()
    local tw = pad_x * 2 + icon_sz + gap + label_sz.w
    local th = math.max(UI.sz(32), icon_sz, label_sz.h) + pad_y * 2
    local tap = tappable(tw, th, callback)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = tw, h = th },
        HorizontalGroup:new{
            align = "center",
            loadIcon(icon_name, icon_sz),
            HorizontalSpan:new{ width = gap },
            label,
        },
    }
    return tap
end

--- 与官方 Menu 底栏一致：首/上/页码/下/末 + chevron 图标（尺寸跟 ui_scale）
local function menuPager(page, pages, handlers)
    handlers = handlers or {}
    page = tonumber(page) or 1
    pages = math.max(1, tonumber(pages) or 1)
    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    local chevron_first = "chevron.first"
    local chevron_last = "chevron.last"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
        chevron_first, chevron_last = chevron_last, chevron_first
    end
    local icon_sz = UI.iconSz()
    local spacer = HorizontalSpan:new{ width = UI.sz(32) }
    local function chev(icon, cb)
        return Button:new{
            icon = icon,
            icon_width = icon_sz,
            icon_height = icon_sz,
            bordersize = 0,
            padding = UI.sz(2),
            callback = cb,
        }
    end
    local first = chev(chevron_first, function()
        if handlers.on_first then handlers.on_first() end
    end)
    local left = chev(chevron_left, function()
        if handlers.on_prev then handlers.on_prev() end
    end)
    local right = chev(chevron_right, function()
        if handlers.on_next then handlers.on_next() end
    end)
    local last = chev(chevron_last, function()
        if handlers.on_last then handlers.on_last() end
    end)
    local info = Button:new{
        text = T(_("Page %1 of %2"), page, pages),
        text_font_face = "xx_smallinfofont",
        text_font_size = UI.fontSize(16),
        text_font_bold = false,
        bordersize = 0,
        padding = UI.sz(2),
    }
    if info.disableWithoutDimming then
        info:disableWithoutDimming()
    end
    first:enableDisable(page > 1)
    left:enableDisable(page > 1)
    right:enableDisable(page < pages)
    last:enableDisable(page < pages)
    return HorizontalGroup:new{
        first,
        spacer,
        left,
        spacer,
        info,
        spacer,
        right,
        spacer,
        last,
    }
end

local function pickFilterList(data, def)
    if type(data) ~= "table" or not def then return {} end
    local list = data[def.list_key]
    if type(list) == "table" and #list > 0 then
        return list
    end
    for _, alt in ipairs(def.aliases or {}) do
        local alt_list = data[alt]
        if type(alt_list) == "table" and #alt_list > 0 then
            return alt_list
        end
    end
    return type(list) == "table" and list or {}
end

--- 筛选互斥：同一时刻只保留一个条件（含 search）
function Library.applyExclusive(desktop, key, value)
    desktop.filter = {}
    if key and value and value ~= "" then
        desktop.filter[key] = value
    end
    desktop.page = 1
    desktop._library_state = nil
    desktop.tab = "library"
    desktop:rebuild()
end

local function bookFile(book)
    if type(book) ~= "table" then return nil end
    return book.filename or book.fileName or book.file or book.path
end

local function bookPct(book)
    local pct = tonumber(book.progressPercent) or 0
    if type(book.progressPercent) == "string" then
        pct = tonumber((book.progressPercent:gsub("%%", ""):match("[%d%.]+"))) or 0
    end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    return pct
end

local function coverCell(ctx, book, slot_w, cw, ch, on_open)
    local title = bookTitle(book)
    local filename = bookFile(book)
    local path = Cover.cachedPath(ctx.plugin, filename)
    local cover = Cover.widget(path, cw, ch, title)
    if not path and filename then
        Cover.ensureAsync(ctx.source, ctx.plugin, filename, nil)
    end

    local pct = bookPct(book)
    -- 有进度才叠右上角角标（黑底白字 + 白边，深浅封面都可读）
    if pct > 0 then
        local badge = FrameContainer:new{
            bordersize = math.max(1, UI.line()),
            color = Blitbuffer.COLOR_WHITE,
            padding = UI.sz(2),
            padding_left = UI.sz(4),
            padding_right = UI.sz(4),
            background = Blitbuffer.COLOR_BLACK,
            TextWidget:new{
                text = string.format("%.0f%%", pct),
                face = UI.face("xx_smallinfofont", 11),
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        }
        local bz = badge:getSize()
        local inset = UI.sz(3)
        badge.overlap_offset = {
            math.max(0, cw - bz.w - inset),
            inset,
        }
        cover = OverlapGroup:new{
            dimen = Geom:new{ w = cw, h = ch },
            cover,
            badge,
        }
    end

    local title_gap = UI.sz(4)
    local title_h = UI.sz(22)
    local total_h = ch + title_gap + title_h
    local tap = tappable(slot_w, total_h, function()
        if on_open then on_open(book) end
    end)
    tap[1] = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = ch },
            cover,
        },
        VerticalSpan:new{ width = title_gap },
        TextWidget:new{
            text = title,
            face = UI.face("xx_smallinfofont", 13),
            max_width = slot_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap, total_h
end

--- 按内容区尺寸算出网格容量；请求 pageSize 必须与此一致，否则多出来的书会被屏外丢掉
function Library.gridMetrics(w, h)
    w = math.max(1, tonumber(w) or 1)
    h = math.max(1, tonumber(h) or 1)
    local pad = UI.sz(12)
    local top_h = UI.sz(52)
    local bottom_pad = UI.sz(10)
    local bottom_h = UI.iconSz() + UI.sz(28) + bottom_pad
    local grid_h = math.max(1, h - top_h - bottom_h)
    local row_gap = UI.sz(12)
    local avail = math.max(1, w - pad * 2)
    local slot_w, cw, ch, cols, gap = UI.coverGridMetrics(avail, grid_h, {
        min_cw = UI.sz(56),
        min_cols = 2,
        max_cols = 5,
    })
    local cell_h = ch + UI.sz(4) + UI.sz(22)
    local rows = 0
    local used = 0
    while used + cell_h <= grid_h do
        rows = rows + 1
        used = used + cell_h + row_gap
    end
    if rows < 1 then rows = 1 end
    return {
        pad = pad,
        top_h = top_h,
        bottom_pad = bottom_pad,
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

function Library.build(ctx, state, opts)
    opts = opts or {}
    local w = ctx.width
    local h = ctx.height
    local m = Library.gridMetrics(w, h)
    local pad = m.pad
    local page = opts.page or 1
    local pages = opts.pages or 1
    local total = opts.total or 0
    local books = state.books
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end

    local tools = HorizontalGroup:new{
        iconAction("search.svg", _("搜索"), function()
            if ctx.desktop then ctx.desktop:showSearch() end
        end),
        HorizontalSpan:new{ width = UI.sz(8) },
        iconAction("filter.svg", _("筛选"), function()
            if ctx.desktop then Library.showFilterRoot(ctx.desktop) end
        end),
        HorizontalSpan:new{ width = UI.sz(8) },
        iconAction("clear.svg", _("清除"), function()
            if ctx.desktop then ctx.desktop:clearLibraryFilters() end
        end),
    }
    local total_label = TextWidget:new{
        text = T(_("共%1"), total),
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    }
    local tools_w = tools:getSize().w
    local total_w = total_label:getSize().w
    local mid = math.max(UI.sz(8), (w - pad * 2) - tools_w - total_w)
    local toolbar = HorizontalGroup:new{
        align = "center",
        tools,
        HorizontalSpan:new{ width = mid },
        total_label,
    }

    local pager = menuPager(page, pages, {
        on_prev = opts.on_prev,
        on_next = opts.on_next,
        on_first = opts.on_first,
        on_last = opts.on_last,
    })

    local top = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        padding_bottom = UI.sz(4),
        background = Blitbuffer.COLOR_WHITE,
        toolbar,
    }

    local top_h = m.top_h
    local bottom_pad = m.bottom_pad
    local bottom_h = m.bottom_h
    local grid_h = m.grid_h

    if not books then
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new{
                top,
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = grid_h + bottom_h },
                    TextWidget:new{
                        text = opts.loading_text or _("加载图书馆…"),
                        face = UI.face("cfont", 18),
                        fgcolor = UI.muted(),
                    },
                },
            },
        }
    end

    if #books == 0 then
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new{
                top,
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = grid_h },
                    TextWidget:new{
                        text = state.err or opts.empty_text or _("没有书籍"),
                        face = UI.face("cfont", 16),
                        fgcolor = UI.muted(),
                    },
                },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = bottom_h },
                    VerticalGroup:new{
                        align = "center",
                        pager,
                        VerticalSpan:new{ width = bottom_pad },
                    },
                },
            },
        }
    end

    local gap = m.gap
    local cols = m.cols
    local slot_w = m.slot_w or m.cw
    local cw = m.cw
    local ch = m.ch
    local row_gap = m.row_gap
    local estimate_h = m.cell_h

    local grid = VerticalGroup:new{ align = "center" }
    local row = HorizontalGroup:new{}
    local col_i = 0
    local used_h = 0
    local cell_h

    -- pageSize 已按容量请求；这里只兜底，正常应能画完本页全部
    for _, book in ipairs(books) do
        if col_i == 0 and used_h + estimate_h > grid_h then
            break
        end
        local cell, th = coverCell(ctx, book, slot_w, cw, ch, on_open)
        cell_h = th
        if col_i > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, cell)
        col_i = col_i + 1
        if col_i >= cols then
            table.insert(grid, row)
            table.insert(grid, VerticalSpan:new{ width = row_gap })
            used_h = used_h + th + row_gap
            row = HorizontalGroup:new{}
            col_i = 0
        end
    end
    if col_i > 0 and used_h + (cell_h or 0) <= grid_h then
        table.insert(grid, row)
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            top,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = grid_h },
                grid,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = bottom_h },
                VerticalGroup:new{
                    align = "center",
                    pager,
                    VerticalSpan:new{ width = bottom_pad },
                },
            },
        },
    }
end

function Library.fetch(desktop)
    local function done(books, err)
        if desktop._closed or desktop.tab ~= "library" then return end
        desktop._library_state = {
            books = books or {},
            err = err,
        }
        desktop:rebuild()
    end

    local function run()
        local source = desktop.source
        if not source or not source.configured or not source:configured() then
            done({}, _("请先在设置里配置当前数据源"))
            return
        end
        desktop:syncLibraryPageSize()
        local f = desktop.filter or {}
        local res, err
        local ok, thrown = pcall(function()
            res, err = source:listLibrary{
                page = desktop.page or 1,
                pageSize = desktop.page_size or 1,
                search = f.search or "",
                favorite = f.favorite or "",
                category = f.category or "",
                series = f.series or "",
                author = f.author or "",
                finished = f.finished or "",
            }
        end)
        if not ok then
            done({}, tostring(thrown))
            return
        end
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        desktop.total = tonumber(res.count) or 0
        local books = res.data or {}
        Cache.rememberMany(books)
        done(books)
    end

    UIManager:scheduleIn(0, function()
        local ok, err = pcall(run)
        if not ok then
            done({}, tostring(err))
        end
    end)
end

function Library.showFilterRoot(desktop)
    local items = {}
    for _, kind in ipairs(FILTER_ORDER) do
        local def = FILTER_KINDS[kind]
        local k = kind
        table.insert(items, {
            text = def.label,
            callback = function()
                if desktop._filter_root then
                    UIManager:close(desktop._filter_root)
                    desktop._filter_root = nil
                end
                Library.showFilterPicker(desktop, k)
            end,
        })
    end

    local menu = Menu:new{
        title = _("筛选"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_font_size = UI.menuFontSize(),
        close_callback = function()
            desktop._filter_root = nil
        end,
    }
    desktop._filter_root = menu
    UIManager:show(menu)
end

function Library.showFilterPicker(desktop, kind)
    local def = FILTER_KINDS[kind]
    if not def then
        logger.warn("book unknown filter kind", kind)
        return
    end
    local title = def.title
    local query_key = def.query_key

    local function applyList(names)
        local items = {{
            text = _("全部"),
            callback = function()
                UIManager:close(desktop._filter_menu)
                desktop._filter_menu = nil
                Library.applyExclusive(desktop, query_key, "")
            end,
        }}
        for _, name in ipairs(names or {}) do
            local n = tostring(name)
            table.insert(items, {
                text = n,
                callback = function()
                    UIManager:close(desktop._filter_menu)
                    desktop._filter_menu = nil
                    Library.applyExclusive(desktop, query_key, n)
                end,
            })
        end
        if #(names or {}) == 0 then
            table.insert(items, { text = _("（暂无）"), enabled = false })
        end
        if desktop._filter_menu then
            desktop._filter_menu:switchItemTable(title, items)
            UIManager:setDirty(desktop._filter_menu, "ui")
        end
    end

    local menu = Menu:new{
        title = title,
        item_table = { { text = _("加载中…"), enabled = false } },
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_font_size = UI.menuFontSize(),
        close_callback = function()
            desktop._filter_menu = nil
        end,
    }
    desktop._filter_menu = menu
    UIManager:show(menu)

    local function fetch()
        local source = desktop.source
        if not source or not source.configured or not source:configured() then
            applyList({})
            return
        end
        local res, err = source:filters()
        if not res then
            logger.warn("book filters failed", err)
            applyList({})
            return
        end
        applyList(pickFilterList(res.data or {}, def))
    end

    UIManager:scheduleIn(0, function()
        local ok, err = pcall(fetch)
        if not ok then
            logger.warn("book filters picker failed", err)
            applyList({})
        end
    end)
end

return Library
