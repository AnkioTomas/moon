--[[--
首页模块：最近阅读 — 只走 Book API（/index/book/recent）

@module koplugin.book.modules.recent
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local NetworkMgr = require("ui/network/manager")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local M = {
    id = "recent",
    title = "最近阅读",
}

local function coverCell(ctx, book, cw, ch)
    local title = book.bookName or book.filename or "?"
    local path = nil
    if ctx.api and ctx.plugin and book.filename then
        path = Cover.ensure(ctx.api, ctx.plugin, book.filename)
    end
    local cover_w = Cover.widget(path, cw, ch, title)
    local label_h = UI.sz(36)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = cw, h = ch + label_h },
    }
    tap.ges_events = {
        TapCover = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapCover = function()
        if ctx.plugin then
            ctx.plugin:openBook(book)
        end
        return true
    end
    tap[1] = VerticalGroup:new{
        align = "center",
        cover_w,
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = title,
            face = UI.face("xx_smallinfofont", 14),
            max_width = cw,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap
end

local function buildContent(ctx, books, status_text)
    local w = ctx.width
    local pad = UI.sz(12)
    local cw = UI.sz(100)
    local ch = UI.sz(145)
    local label_h = UI.sz(36)

    local header = LeftContainer:new{
        dimen = Geom:new{ w = w, h = UI.sz(32) },
        TextWidget:new{
            text = "  " .. _("最近阅读"),
            face = UI.face("cfont", 20),
            bold = true,
        },
    }

    local row = HorizontalGroup:new{}
    table.insert(row, HorizontalSpan:new{ width = pad })
    if status_text then
        table.insert(row, TextWidget:new{
            text = status_text,
            face = UI.face("xx_smallinfofont", 16),
            fgcolor = Blitbuffer.gray(0.5),
        })
    elseif not books or #books == 0 then
        table.insert(row, TextWidget:new{
            text = _("暂无进度 · 打开书库读一本就会出现在这里"),
            face = UI.face("xx_smallinfofont", 16),
            fgcolor = Blitbuffer.gray(0.5),
        })
    else
        for i, book in ipairs(books) do
            table.insert(row, coverCell(ctx, book, cw, ch))
            if i < #books then
                table.insert(row, HorizontalSpan:new{ width = UI.sz(10) })
            end
        end
    end

    local h = UI.sz(32) + ch + label_h + UI.sz(16)
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = UI.sz(8) },
            row,
        },
    }
end

local function fetchRecent(ctx)
    local desk = ctx.desktop
    if not desk or desk._closed then return end
    if desk._recent_loading then return end
    desk._recent_loading = true

    local function done(books, err)
        desk._recent_loading = false
        if desk._closed or desk.tab ~= "home" then return end
        desk._recent_books = books or {}
        desk._recent_err = err
        desk:rebuild()
    end

    local function fetch()
        if not ctx.api or not ctx.api:configured() then
            done({}, _("请先配置服务器"))
            return
        end
        local res, err
        local ok, thrown = pcall(function()
            res, err = ctx.api:recentBooks(8)
        end)
        if not ok then
            logger.err("book recent", thrown)
            done({}, tostring(thrown))
            return
        end
        if not res then
            done({}, err or _("加载失败"))
            return
        end
        done(res.data or {})
    end

    if NetworkMgr.isOnline and NetworkMgr:isOnline() then
        fetch()
    else
        NetworkMgr:runWhenOnline(fetch)
    end
end

function M.build(ctx)
    local desk = ctx.desktop
    if desk and desk._recent_books ~= nil then
        local err = desk._recent_err
        if err and #(desk._recent_books or {}) == 0 then
            return buildContent(ctx, nil, err)
        end
        return buildContent(ctx, desk._recent_books)
    end

    UIManager:nextTick(function()
        fetchRecent(ctx)
    end)
    return buildContent(ctx, nil, _("加载最近阅读…"))
end

return M
