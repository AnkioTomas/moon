--[[--
图书馆：搜索 / 分类 / 系列 / 分页封面网格（异步封面）

@module koplugin.book.library
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Library = {}

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

local function filterLabel(filter)
    local parts = {}
    if filter.search and filter.search ~= "" then
        table.insert(parts, T(_("搜:%1"), filter.search))
    end
    if filter.category and filter.category ~= "" then
        table.insert(parts, filter.category)
    end
    if filter.series and filter.series ~= "" then
        table.insert(parts, filter.series)
    end
    if filter.favorite and filter.favorite ~= "" then
        table.insert(parts, filter.favorite)
    end
    if #parts == 0 then return _("全部") end
    return table.concat(parts, " · ")
end

local function coverCell(ctx, book, cw, ch, on_open)
    local title = bookTitle(book)
    local path = Cover.cachedPath(ctx.plugin, book.filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path then
        Cover.ensureAsync(ctx.api, ctx.plugin, book.filename, nil)
    end
    local pct = tonumber(book.progressPercent) or 0
    if type(book.progressPercent) == "string" then
        pct = tonumber((book.progressPercent:gsub("%%", ""):match("[%d%.]+"))) or 0
    end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local sub = pct > 0 and string.format("%.0f%%", pct) or (book.author or "")
    local label_h = UI.sz(40)
    local tap = tappable(cw, ch + label_h, function()
        if on_open then on_open(book) end
    end)
    tap[1] = VerticalGroup:new{
        align = "center",
        cover_w,
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = title,
            face = UI.face("xx_smallinfofont", 13),
            max_width = cw,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        TextWidget:new{
            text = sub,
            face = UI.face("xx_smallinfofont", 12),
            max_width = cw,
            fgcolor = Blitbuffer.gray(0.45),
        },
    }
    return tap, ch + label_h
end

local function toolButton(text, callback)
    return Button:new{
        text = text,
        bordersize = 1,
        margin = 0,
        padding = UI.sz(6),
        text_font_face = "xx_smallinfofont",
        text_font_size = math.max(12, math.floor(14 * UI.getScale() / 100 + 0.5)),
        callback = callback,
    }
end

function Library.build(ctx, state, opts)
    opts = opts or {}
    local w = ctx.width
    local h = ctx.height
    local pad = UI.sz(10)
    local filter = ctx.filter or {}
    local page = opts.page or 1
    local pages = opts.pages or 1
    local total = opts.total or 0
    local books = state.books
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end

    local toolbar = HorizontalGroup:new{
        toolButton(_("搜索"), function()
            if ctx.desktop then ctx.desktop:showSearch() end
        end),
        HorizontalSpan:new{ width = UI.sz(6) },
        toolButton(_("分类"), function()
            if ctx.desktop then ctx.desktop:showFilterPicker("category") end
        end),
        HorizontalSpan:new{ width = UI.sz(6) },
        toolButton(_("系列"), function()
            if ctx.desktop then ctx.desktop:showFilterPicker("series") end
        end),
        HorizontalSpan:new{ width = UI.sz(6) },
        toolButton(_("清除"), function()
            if ctx.desktop then ctx.desktop:clearLibraryFilters() end
        end),
    }

    local header = LeftContainer:new{
        dimen = Geom:new{ w = w, h = UI.sz(28) },
        TextWidget:new{
            text = T(_("图书馆 · %1  ·  %2/%3  ·  共%4"),
                filterLabel(filter), page, pages, total),
            face = UI.face("xx_smallinfofont", 13),
            max_width = w - pad * 2,
            fgcolor = Blitbuffer.gray(0.4),
        },
    }

    local pager = HorizontalGroup:new{
        toolButton(_("上一页"), function()
            if opts.on_prev then opts.on_prev() end
        end),
        HorizontalSpan:new{ width = UI.sz(12) },
        TextWidget:new{
            text = string.format("%d / %d", page, pages),
            face = UI.face("xx_smallinfofont", 14),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        HorizontalSpan:new{ width = UI.sz(12) },
        toolButton(_("下一页"), function()
            if opts.on_next then opts.on_next() end
        end),
    }

    local top = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        padding_bottom = UI.sz(4),
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            toolbar,
            VerticalSpan:new{ width = UI.sz(6) },
            header,
        },
    }

    local top_h = UI.sz(78)
    local bottom_h = UI.sz(48)
    local grid_h = math.max(1, h - top_h - bottom_h)

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
                        text = _("加载图书馆…"),
                        face = UI.face("cfont", 18),
                        fgcolor = Blitbuffer.gray(0.45),
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
                        text = state.err or _("没有书籍"),
                        face = UI.face("cfont", 16),
                        fgcolor = Blitbuffer.gray(0.45),
                    },
                },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = bottom_h },
                    pager,
                },
            },
        }
    end

    local cw = UI.sz(100)
    local ch = UI.sz(145)
    local gap = UI.sz(10)
    local cols = math.max(1, math.floor((w - pad * 2 + gap) / (cw + gap)))
    local grid = VerticalGroup:new{ align = "center" }
    local row = HorizontalGroup:new{}
    local col_i = 0
    local used_h = 0
    local cell_h

    for _, book in ipairs(books) do
        local cell, th = coverCell(ctx, book, cw, ch, on_open)
        cell_h = th
        if col_i == 0 and used_h + th > grid_h then
            break
        end
        if col_i > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, cell)
        col_i = col_i + 1
        if col_i >= cols then
            if used_h + th > grid_h then
                break
            end
            table.insert(grid, row)
            table.insert(grid, VerticalSpan:new{ width = UI.sz(8) })
            used_h = used_h + th + UI.sz(8)
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
                pager,
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
        if books then
            -- total 已在 fetch 内写入 desktop.total
        end
        desktop:rebuild()
    end

    local function run()
        if not desktop.api or not desktop.api:configured() then
            done({}, _("请先在设置里配置服务器与令牌"))
            return
        end
        local res, err
        local ok, thrown = pcall(function()
            res, err = desktop.api:listBooks{
                page = desktop.page or 1,
                pageSize = desktop.page_size or 12,
                search = desktop.filter.search or "",
                category = desktop.filter.category or "",
                series = desktop.filter.series or "",
                favorite = desktop.filter.favorite or "",
                finished = desktop.filter.finished or "",
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
        done(res.data or {})
    end

    -- 直接拉；离线时 API 会报错，由 done 展示，避免卡在加载
    UIManager:scheduleIn(0, function()
        local ok, err = pcall(run)
        if not ok then
            done({}, tostring(err))
        end
    end)
end

function Library.showFilterPicker(desktop, kind)
    local title = kind == "series" and _("选择系列") or _("选择分类")
    local key = kind == "series" and "series" or "categories"
    local filter_key = kind == "series" and "series" or "category"

    local function applyList(names)
        local items = {{
            text = _("全部"),
            callback = function()
                desktop.filter[filter_key] = ""
                desktop.page = 1
                desktop._library_state = nil
                UIManager:close(desktop._filter_menu)
                desktop._filter_menu = nil
                desktop.tab = "library"
                desktop:rebuild()
            end,
        }}
        for _, name in ipairs(names or {}) do
            local n = name
            table.insert(items, {
                text = n,
                callback = function()
                    desktop.filter[filter_key] = n
                    desktop.page = 1
                    desktop._library_state = nil
                    UIManager:close(desktop._filter_menu)
                    desktop._filter_menu = nil
                    desktop.tab = "library"
                    desktop:rebuild()
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
        if not desktop.api or not desktop.api:configured() then
            applyList({})
            return
        end
        local res, err = desktop.api:filters()
        if not res then
            logger.warn("book filters failed", err)
            applyList({})
            return
        end
        local data = res.data or {}
        local list = data[key] or data[filter_key] or {}
        -- 兼容 favorites 当分类的旧字段
        if kind == "category" and #list == 0 and data.favorites then
            list = data.favorites
        end
        applyList(list)
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
