--[[--
主页：顶部时钟/一言 · 统计 · 最近阅读 · 在读网格（高度裁剪）

@module koplugin.book.home
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
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
local Screen = Device.screen

local Home = {}

local WEEKDAYS = {
    _("星期日"), _("星期一"), _("星期二"), _("星期三"),
    _("星期四"), _("星期五"), _("星期六"),
}

local function settings()
    return G_reader_settings:readSetting(UI.settingsKey()) or {}
end

local function bookTitle(book)
    return book.bookName or book.filename or "?"
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

-- 只预热缓存，不刷新 UI（刷新会连环 rebuild → 墨水屏直接崩）
local function prefetchCover(api, plugin, filename)
    if not filename then return end
    Cover.ensureAsync(api, plugin, filename, nil)
end

function Home.buildHeader(ctx, state)
    local w = ctx.width
    local s = settings()
    local mode = s.home_header or "clock"
    local pad = UI.sz(16)
    local header_h = UI.sz(110)

    if mode == "hitokoto" then
        local text = state.hitokoto_text or _("加载一言…")
        local from = state.hitokoto_from or ""
        local box = TextBoxWidget:new{
            text = text,
            face = UI.face("cfont", 18),
            width = w - pad * 2,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local kids = {
            align = "center",
            box,
        }
        if from ~= "" then
            table.insert(kids, VerticalSpan:new{ width = UI.sz(6) })
            table.insert(kids, TextWidget:new{
                text = "— " .. from,
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = Blitbuffer.gray(0.4),
            })
        end
        return FrameContainer:new{
            bordersize = 0,
            padding = pad,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = header_h },
            CenterContainer:new{
                dimen = Geom:new{ w = w - pad * 2, h = header_h - pad },
                VerticalGroup:new(kids),
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
            battery = T(_("  电量 %1%%"), pct)
        end
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = header_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w - pad * 2, h = header_h - pad },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = time_str,
                    face = UI.face("cfont", 48),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
                VerticalSpan:new{ width = UI.sz(4) },
                TextWidget:new{
                    text = date_str .. battery,
                    face = UI.face("xx_smallinfofont", 16),
                    fgcolor = Blitbuffer.gray(0.4),
                },
            },
        },
    }
end

function Home.buildStats(ctx, state)
    local w = ctx.width
    local pad = UI.sz(12)
    local stats = state.stats or {}
    local function cell(label, value)
        local v = value
        if v == nil then v = "—" end
        return CenterContainer:new{
            dimen = Geom:new{ w = math.floor((w - pad * 2) / 3), h = UI.sz(64) },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = tostring(v),
                    face = UI.face("cfont", 22),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
                VerticalSpan:new{ width = UI.sz(2) },
                TextWidget:new{
                    text = label,
                    face = UI.face("xx_smallinfofont", 13),
                    fgcolor = Blitbuffer.gray(0.45),
                },
            },
        }
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = UI.sz(80) },
        HorizontalGroup:new{
            cell(_("藏书"), stats.total),
            cell(_("已读"), stats.finished),
            cell(_("未读"), stats.unread),
        },
    }
end

local function recentRow(ctx, book, on_open)
    local w = ctx.width
    local pad = UI.sz(12)
    local cw = UI.sz(72)
    local ch = UI.sz(100)
    local title = bookTitle(book)
    local author = bookAuthor(book)
    local pct = bookPct(book)
    local path = Cover.cachedPath(ctx.plugin, book.filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path then
        prefetchCover(ctx.api, ctx.plugin, book.filename)
    end

    local info_w = math.max(UI.sz(40), w - pad * 2 - cw - UI.sz(12))
    local bar = UI.progressBar(info_w, UI.sz(8), pct)
    local info = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 18),
            max_width = info_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = author ~= "" and author or _("未知作者"),
            face = UI.face("xx_smallinfofont", 14),
            max_width = info_w,
            fgcolor = Blitbuffer.gray(0.45),
        },
        VerticalSpan:new{ width = UI.sz(10) },
        bar,
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = string.format("%.0f%%", pct),
            face = UI.face("xx_smallinfofont", 13),
            fgcolor = Blitbuffer.gray(0.4),
        },
    }

    local row_h = math.max(ch, UI.sz(110))
    local tap = tappable(w, row_h + pad, function()
        if on_open then on_open(book) end
    end)
    tap[1] = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = row_h + pad },
        HorizontalGroup:new{
            cover_w,
            HorizontalSpan:new{ width = UI.sz(12) },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = row_h },
                info,
            },
        },
    }
    return tap, row_h + pad
end

local function readingCell(ctx, book, cw, ch, on_open)
    local title = bookTitle(book)
    local pct = bookPct(book)
    local path = Cover.cachedPath(ctx.plugin, book.filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path then
        prefetchCover(ctx.api, ctx.plugin, book.filename)
    end
    local label_h = UI.sz(28)
    local bar_h = UI.sz(10)
    local total_h = ch + label_h + bar_h + UI.sz(8)
    local tap = tappable(cw, total_h, function()
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
        VerticalSpan:new{ width = UI.sz(2) },
        UI.progressBar(cw, UI.sz(6), pct),
    }
    return tap, total_h
end

function Home.build(ctx, state)
    local w = ctx.width
    local h = ctx.height
    local pad = UI.sz(12)
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end

    local col = VerticalGroup:new{ align = "left" }
    local used = 0

    local header = Home.buildHeader(ctx, state)
    table.insert(col, header)
    used = used + (header.dimen and header.dimen.h or UI.sz(110))

    local stats = Home.buildStats(ctx, state)
    table.insert(col, stats)
    used = used + (stats.dimen and stats.dimen.h or UI.sz(80))

    -- section: 最近阅读
    local recent = state.recent
    table.insert(col, LeftContainer:new{
        dimen = Geom:new{ w = w, h = UI.sz(28) },
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = UI.sz(4),
            padding_bottom = 0,
            TextWidget:new{
                text = _("最近阅读"),
                face = UI.face("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    })
    used = used + UI.sz(28)

    if recent then
        local row, rh = recentRow(ctx, recent, on_open)
        table.insert(col, row)
        used = used + rh
    else
        local empty_h = UI.sz(40)
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

    table.insert(col, LeftContainer:new{
        dimen = Geom:new{ w = w, h = UI.sz(28) },
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = UI.sz(4),
            padding_bottom = 0,
            TextWidget:new{
                text = _("在读"),
                face = UI.face("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    })
    used = used + UI.sz(28)

    local reading = state.reading or {}
    local remain = h - used - UI.sz(8)
    if #reading == 0 then
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.max(UI.sz(40), remain) },
            TextWidget:new{
                text = _("没有在读的书"),
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = Blitbuffer.gray(0.5),
            },
        })
    else
        local cw = UI.sz(90)
        local ch = UI.sz(130)
        local gap = UI.sz(10)
        local cols = math.max(1, math.floor((w - pad * 2 + gap) / (cw + gap)))
        local cell_h
        local row_group = HorizontalGroup:new{}
        local grid = VerticalGroup:new{ align = "left" }
        local col_i = 0
        local grid_h = 0

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
                table.insert(grid, FrameContainer:new{
                    bordersize = 0,
                    padding = pad,
                    padding_top = UI.sz(4),
                    padding_bottom = 0,
                    row_group,
                })
                grid_h = grid_h + cell_h + UI.sz(4)
                row_group = HorizontalGroup:new{}
                col_i = 0
            end
        end
        if col_i > 0 and grid_h + (cell_h or 0) <= remain then
            table.insert(grid, FrameContainer:new{
                bordersize = 0,
                padding = pad,
                padding_top = UI.sz(4),
                padding_bottom = 0,
                row_group,
            })
        end
        table.insert(col, grid)
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
