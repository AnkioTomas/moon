--[[--
主页：顶部时钟/一言 · 精简统计 · 最近阅读（主角） · 在读网格

@module koplugin.book.home
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Home = {}

local WEEKDAYS = {
    _("星期日"), _("星期一"), _("星期二"), _("星期三"),
    _("星期四"), _("星期五"), _("星期六"),
}

local function settings()
    return G_reader_settings:readSetting(UI.settingsKey()) or {}
end

local function pluginIconDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("(.*/)")
        if dir then return dir .. "icons/" end
    end
    return "icons/"
end

local function loadIcon(name, size)
    size = size or UI.sz(16)
    local ok, img = pcall(function()
        return ImageWidget:new{
            file = pluginIconDir() .. name,
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
        face = UI.face("cfont", 12),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

local function bookFile(book)
    if type(book) ~= "table" then return nil end
    return book.filename or book.fileName or book.file or book.path or book.name
end

local function bookTitle(book)
    return book.bookName or book.title or bookFile(book) or "?"
end

local function bookAuthor(book)
    return book.author or ""
end

local function bookPct(book)
    local p = book and book.progressPercent
    if type(p) == "string" then
        p = p:gsub("%%", ""):match("[%d%.]+")
    end
    p = tonumber(p) or 0
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end
    return p
end

local function isFinished(book)
    local f = book.finished
    return f == true or f == 1 or f == "1"
end

local function tappable(w, h, on_tap)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapHome = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapHome = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

-- 只预热缓存；成功后由 Cover idle handler 统一防抖刷新
local function prefetchCover(api, plugin, filename)
    if not filename then return end
    Cover.ensureAsync(api, plugin, filename, nil)
end

local function openLibrary(desktop, finished)
    if not desktop or not desktop.switchTab then return end
    desktop.filter = {}
    if finished ~= nil and finished ~= "" then
        desktop.filter.finished = finished
    end
    desktop.page = 1
    desktop._library_state = nil
    desktop:switchTab("library")
end

local function sectionTitle(text, width, pad)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(30) },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad,
            margin = 0,
            TextWidget:new{
                text = text,
                face = UI.face("cfont", 13),
                fgcolor = Blitbuffer.gray(0.4),
            },
        },
    }
end

local function progressBadge(cw, pct)
    if not pct or pct <= 0 then
        return nil
    end
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
    return badge
end

function Home.buildHeader(ctx, state)
    local w = ctx.width
    local s = settings()
    local mode = s.home_header or "clock"
    local pad = UI.sz(16)

    if mode == "hitokoto" then
        local text = state.hitokoto_text or _("加载一言…")
        local from = state.hitokoto_from or ""
        local inner_w = w - pad * 2
        local box = TextBoxWidget:new{
            text = text,
            face = UI.face("cfont", 18),
            width = inner_w,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local kids = { align = "center", box }
        if from ~= "" then
            table.insert(kids, VerticalSpan:new{ width = UI.sz(8) })
            table.insert(kids, RightContainer:new{
                dimen = Geom:new{ w = inner_w, h = UI.sz(22) },
                TextWidget:new{
                    text = "— " .. from,
                    face = UI.face("xx_smallinfofont", 13),
                    max_width = inner_w,
                    fgcolor = Blitbuffer.gray(0.4),
                },
            })
        end
        local body = VerticalGroup:new(kids)
        local body_h = body:getSize().h
        local header_h = math.max(UI.sz(88), body_h + pad * 2)
        return FrameContainer:new{
            bordersize = 0,
            padding = pad,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = header_h },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = body_h },
                body,
            },
        }
    end

    local now = os.date("*t")
    local time_str = string.format("%02d:%02d", now.hour, now.min)
    local date_str = string.format("%04d-%02d-%02d  %s",
        now.year, now.month, now.day, WEEKDAYS[(now.wday or 1)])
    local battery = ""
    if Device.powerd then
        local ok, pct = pcall(function() return Device.powerd:getCapacity() end)
        if ok and type(pct) == "number" then
            battery = T(_("电量 %1%"), pct)
        end
    end

    local meta_h = UI.sz(24)
    local meta = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = math.floor((w - pad * 2) * 0.62), h = meta_h },
            TextWidget:new{
                text = date_str,
                face = UI.face("xx_smallinfofont", 14),
                max_width = math.floor((w - pad * 2) * 0.62),
                fgcolor = Blitbuffer.gray(0.4),
            },
        },
        RightContainer:new{
            dimen = Geom:new{ w = math.floor((w - pad * 2) * 0.38), h = meta_h },
            TextWidget:new{
                text = battery,
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = Blitbuffer.gray(0.4),
            },
        },
    }

    local header_h = UI.sz(118)
    return FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = header_h },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = time_str,
                face = UI.face("cfont", 52),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(8) },
            meta,
        },
    }
end

--- 一行精简统计，可点进图书馆
function Home.buildStats(ctx, state)
    local w = ctx.width
    local pad = UI.sz(12)
    local stats = state.stats or {}
    local desktop = ctx.desktop
    local inner_w = w - pad * 2
    local cell_w = math.floor(inner_w / 3)
    local row_h = UI.sz(48)
    local icon_sz = UI.sz(16)

    local function cell(icon_name, label, value, finished_filter)
        local v = value
        if v == nil then v = "—" end
        local tap = tappable(cell_w, row_h, function()
            openLibrary(desktop, finished_filter)
        end)
        tap[1] = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = row_h },
            HorizontalGroup:new{
                align = "center",
                loadIcon(icon_name, icon_sz),
                HorizontalSpan:new{ width = UI.sz(4) },
                TextWidget:new{
                    text = T("%1 %2", label, tostring(v)),
                    face = UI.face("xx_smallinfofont", 14),
                    max_width = math.max(UI.sz(20), cell_w - icon_sz - UI.sz(10)),
                    fgcolor = Blitbuffer.gray(0.35),
                },
            },
        }
        return tap
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        padding_top = UI.sz(2),
        padding_bottom = UI.sz(6),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = row_h + UI.sz(8) },
        HorizontalGroup:new{
            align = "center",
            cell("library.svg", _("藏书"), stats.total, nil),
            cell("finished.svg", _("已读"), stats.finished, "1"),
            cell("unread.svg", _("未读"), stats.unread, "0"),
        },
    }
end

--- 与「在读」网格同一套封面尺度
local function coverMetrics(width, pad)
    local gap = UI.sz(12)
    local avail = math.max(1, width - pad * 2)
    local cols = 3
    local cw = math.floor((avail - gap * (cols - 1)) / cols)
    if cw < UI.sz(72) then
        cols = 2
        cw = math.floor((avail - gap * (cols - 1)) / cols)
    end
    cw = math.max(UI.sz(64), cw)
    local ch = math.floor(cw * 3 / 2)
    return cw, ch, cols, gap, avail
end

local function recentRow(ctx, book, on_open, on_read, grid_cw, avail, pad)
    local w = ctx.width
    -- 主角封面：大于在读格，但给右侧文字留足空间
    local cw = math.min(math.floor(grid_cw * 1.4), math.floor(avail * 0.42))
    cw = math.max(grid_cw, cw)
    local ch = math.floor(cw * 3 / 2)
    local gap = UI.sz(16)
    local title = bookTitle(book)
    local author = bookAuthor(book)
    local pct = bookPct(book)
    local filename = bookFile(book)
    local path = Cover.cachedPath(ctx.plugin, filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path and filename then
        prefetchCover(ctx.api, ctx.plugin, filename)
    end
    local badge = progressBadge(cw, pct)
    if badge then
        cover_w = OverlapGroup:new{
            dimen = Geom:new{ w = cw, h = ch },
            cover_w,
            badge,
        }
    end

    local info_w = math.max(UI.sz(40), avail - cw - gap)
    local progress_text = pct > 0 and T(_("已读 %1%"), string.format("%.0f", pct)) or _("尚未开始")

    -- 封面 / 元信息 → 详情；「继续阅读」按钮单独 → 直接打开书
    local cover_tap = tappable(cw, ch, function()
        if on_open then on_open(book) end
    end)
    cover_tap[1] = cover_w

    local meta = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 20),
            max_width = info_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = UI.sz(6) },
        TextWidget:new{
            text = author ~= "" and author or _("未知作者"),
            face = UI.face("xx_smallinfofont", 14),
            max_width = info_w,
            fgcolor = Blitbuffer.gray(0.45),
        },
        VerticalSpan:new{ width = UI.sz(14) },
        UI.progressBar(info_w, UI.sz(8), pct),
        VerticalSpan:new{ width = UI.sz(6) },
        TextWidget:new{
            text = progress_text,
            face = UI.face("xx_smallinfofont", 13),
            max_width = info_w,
            fgcolor = Blitbuffer.gray(0.4),
        },
    }
    local meta_h = meta:getSize().h
    local meta_tap = tappable(info_w, meta_h, function()
        if on_open then on_open(book) end
    end)
    meta_tap[1] = meta

    local read_btn = Button:new{
        text = _("继续阅读 ›"),
        bordersize = 0,
        margin = 0,
        padding = UI.sz(2),
        text_font_face = "cfont",
        text_font_size = UI.fontSize(15),
        text_font_bold = false,
        callback = function()
            if on_read then on_read(book) end
        end,
        show_parent = ctx.desktop,
    }
    local btn_h = read_btn:getSize().h

    local info = VerticalGroup:new{
        align = "left",
        meta_tap,
        VerticalSpan:new{ width = UI.sz(12) },
        LeftContainer:new{
            dimen = Geom:new{ w = info_w, h = btn_h },
            read_btn,
        },
    }

    local row_h = math.max(ch, meta_h + UI.sz(12) + btn_h)
    return FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = row_h + pad },
        HorizontalGroup:new{
            align = "center",
            cover_tap,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = row_h },
                info,
            },
        },
    }, row_h + pad
end

local function readingCell(ctx, book, cw, ch, on_open)
    local title = bookTitle(book)
    local pct = bookPct(book)
    local filename = bookFile(book)
    local path = Cover.cachedPath(ctx.plugin, filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path and filename then
        prefetchCover(ctx.api, ctx.plugin, filename)
    end
    local badge = progressBadge(cw, pct)
    if badge then
        cover_w = OverlapGroup:new{
            dimen = Geom:new{ w = cw, h = ch },
            cover_w,
            badge,
        }
    end
    local title_gap = UI.sz(6)
    local title_h = UI.sz(36)
    local total_h = ch + title_gap + title_h
    local tap = tappable(cw, total_h, function()
        if on_open then on_open(book) end
    end)
    tap[1] = VerticalGroup:new{
        align = "center",
        cover_w,
        VerticalSpan:new{ width = title_gap },
        TextWidget:new{
            text = title,
            face = UI.face("xx_smallinfofont", 13),
            max_width = cw,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap, total_h
end

function Home.build(ctx, state)
    local w = ctx.width
    local h = ctx.height
    local pad = UI.sz(14)
    local section_gap = UI.sz(18)
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end
    local on_read = function(book)
        local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
        if plugin and plugin.openBook then
            plugin:openBook(book)
        elseif on_open then
            on_open(book)
        end
    end

    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    local grid_cw, grid_ch, grid_cols, grid_gap, avail = coverMetrics(w, pad)

    local header = Home.buildHeader(ctx, state)
    table.insert(col, header)
    used = used + (header.dimen and header.dimen.h or UI.sz(110))

    local stats = Home.buildStats(ctx, state)
    table.insert(col, stats)
    used = used + (stats.dimen and stats.dimen.h or UI.sz(52))

    table.insert(col, VerticalSpan:new{ width = section_gap })
    used = used + section_gap

    -- 最近阅读：点卡片进详情；点「继续阅读」直接打开书
    local recent = state.recent
    table.insert(col, sectionTitle(_("最近阅读"), w, pad))
    used = used + UI.sz(30)

    if recent then
        local row, rh = recentRow(ctx, recent, on_open, on_read, grid_cw, avail, pad)
        table.insert(col, row)
        used = used + rh
    else
        local empty_h = UI.sz(48)
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = w, h = empty_h },
            TextWidget:new{
                text = state.recent_err or _("暂无最近阅读"),
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = Blitbuffer.gray(0.5),
            },
        })
        used = used + empty_h
    end

    table.insert(col, VerticalSpan:new{ width = section_gap })
    used = used + section_gap

    local reading = state.reading or {}
    local reading_title = #reading > 0 and T(_("在读 · %1"), #reading) or _("在读")
    table.insert(col, sectionTitle(reading_title, w, pad))
    used = used + UI.sz(30)

    local remain = h - used - UI.sz(8)
    if #reading == 0 then
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.max(UI.sz(48), remain) },
            TextWidget:new{
                text = _("没有在读的书"),
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = Blitbuffer.gray(0.5),
            },
        })
    else
        local cw, ch, cols, gap = grid_cw, grid_ch, grid_cols, grid_gap
        local cell_h
        local row_group = HorizontalGroup:new{}
        local grid = VerticalGroup:new{ align = "left" }
        local col_i = 0
        local grid_h = 0

        local function pushRow(row)
            local rh = (cell_h or ch) + UI.sz(10)
            table.insert(grid, FrameContainer:new{
                bordersize = 0,
                padding = 0,
                padding_left = pad,
                padding_right = pad,
                margin = 0,
                dimen = Geom:new{ w = w, h = rh },
                row,
            })
            grid_h = grid_h + rh
        end

        for _, book in ipairs(reading) do
            local cell, th = readingCell(ctx, book, cw, ch, on_open)
            cell_h = th
            if col_i == 0 and grid_h + cell_h > remain then
                break
            end
            if col_i > 0 then
                table.insert(row_group, HorizontalSpan:new{ width = gap })
            end
            table.insert(row_group, cell)
            col_i = col_i + 1
            if col_i >= cols then
                if grid_h + cell_h > remain then
                    break
                end
                pushRow(row_group)
                row_group = HorizontalGroup:new{}
                col_i = 0
            end
        end
        if col_i > 0 and grid_h + (cell_h or 0) <= remain then
            pushRow(row_group)
        end
        table.insert(col, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = math.max(grid_h, 1) },
            grid,
        })
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        col,
    }
end

--- 异步拉主页数据，写回 desktop 状态后 rebuild
function Home.fetch(desktop)
    if desktop._home_fetching then
        return
    end
    desktop._home_fetching = true

    -- 本会话首次进首页：清理长期未打开的本地下载缓存（不挡 UI）
    if not desktop._local_cleanup_done then
        desktop._local_cleanup_done = true
        UIManager:scheduleIn(0.3, function()
            if desktop._closed then return end
            local plugin = desktop.plugin
            if not plugin or not plugin.cleanupStaleLocalBooks then return end
            local ok, n = pcall(function()
                return plugin:cleanupStaleLocalBooks()
            end)
            if ok and n and n > 0 then
                logger.info("book cleaned stale local books:", n)
            elseif not ok then
                logger.warn("book local cleanup failed", n)
            end
        end)
    end

    local api = desktop.api

    -- 立刻离开「加载主页…」，避免任何网络阻塞把 UI 钉死
    if not desktop._home_loaded then
        desktop._home_state = {
            stats = {},
            recent_err = _("加载中…"),
            reading = {},
        }
        desktop._home_loaded = true
        if not desktop._closed and desktop.tab == "home" then
            desktop:rebuild()
        end
    end

    local function finish(state)
        desktop._home_fetching = false
        desktop._home_state = state or {}
        desktop._home_loaded = true
        if desktop._closed or desktop.tab ~= "home" then return end
        desktop:rebuild()
    end

    local function run()
        if not api or not api:configured() then
            finish({
                stats = {},
                recent_err = _("请先配置服务器"),
                reading = {},
            })
            return
        end

        local state = {}

        -- recent 优先（主页核心）；stats 失败不影响
        local ok_r, rres_or_err, rerr = pcall(function()
            return api:recentBooks(24)
        end)
        local rres = ok_r and rres_or_err or nil
        if not rres then
            state.recent = nil
            state.recent_err = (not ok_r and tostring(rres_or_err)) or rerr or _("加载失败")
            state.reading = {}
        else
            local rows = rres.data or {}
            local recent = rows[1]
            state.recent = recent
            state.recent_err = nil
            local reading = {}
            local skip = recent and recent.filename
            for _, book in ipairs(rows) do
                if book.filename ~= skip and not isFinished(book) and bookPct(book) > 0 then
                    table.insert(reading, book)
                end
            end
            state.reading = reading
        end

        local ok_s, sres_or_err, serr = pcall(function()
            return api:stats()
        end)
        if ok_s and sres_or_err and sres_or_err.data then
            state.stats = {
                total = sres_or_err.data.total,
                finished = sres_or_err.data.finished,
                unread = sres_or_err.data.unread,
            }
        else
            logger.warn("book stats failed:", not ok_s and sres_or_err or serr)
            state.stats = {}
        end

        local mode = (settings().home_header) or "clock"
        if mode == "hitokoto" then
            local ok_h, hres_or_err, herr = pcall(function()
                return api.hitokoto()
            end)
            if ok_h and hres_or_err and hres_or_err.data then
                local d = hres_or_err.data
                state.hitokoto_text = d.hitokoto
                state.hitokoto_from = (d.from_who and d.from_who ~= "" and d.from_who)
                    or d.from or ""
            else
                logger.warn("book hitokoto failed:", not ok_h and hres_or_err or herr)
                state.hitokoto_text = _("一言加载失败")
                state.hitokoto_from = ""
            end
        end

        finish(state)
    end

    UIManager:scheduleIn(0, function()
        local ok, err = pcall(run)
        if not ok then
            logger.err("book home fetch crashed:", err)
            finish({
                stats = {},
                recent_err = tostring(err),
                reading = {},
            })
        end
    end)
end

return Home
