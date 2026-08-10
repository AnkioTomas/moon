--[[--
首页模块：最近阅读封面横滑行（SimpleUI recent / coverdeck 精简版）

@module koplugin.book.modules.recent
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local GestureRange = require("ui/gesturerange")
local Cover = require("cover")
local _ = require("gettext")
local Screen = Device.screen

local M = {
    id = "recent",
    title = "最近阅读",
}

local function recentList(limit)
    limit = limit or 8
    local list = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if not (ok and ReadHistory) then
        return list
    end
    pcall(function()
        if ReadHistory.reload then ReadHistory:reload()
        elseif ReadHistory._read then ReadHistory:_read(true) end
    end)
    local map = G_reader_settings:readSetting("book_plugin_filemap") or {}
    for _, entry in ipairs(ReadHistory.hist or {}) do
        if #list >= limit then break end
        local path = entry.file
        if path then
            local mapped = map[path]
            table.insert(list, {
                title = entry.text or path:match("([^/\\]+)$") or path,
                path = path,
                filename = mapped or path:match("([^/\\]+)$"),
                book = {
                    filename = mapped or path:match("([^/\\]+)$"),
                    bookName = entry.text,
                },
            })
        end
    end
    return list
end

local function coverCell(ctx, item, cw, ch)
    local path = nil
    if ctx.api and ctx.plugin and item.filename then
        path = Cover.ensure(ctx.api, ctx.plugin, item.filename)
    end
    local cover_w = Cover.widget(path, cw, ch, item.title)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = cw, h = ch + Screen:scaleBySize(36) },
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
        if ctx.plugin and item.book then
            ctx.plugin:openBook(item.book)
        end
        return true
    end
    tap[1] = VerticalGroup:new{
        align = "center",
        cover_w,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{
            text = item.title,
            face = Font:getFace("xx_smallinfofont", 12),
            max_width = cw,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap
end

function M.build(ctx)
    local w = ctx.width
    local pad = Screen:scaleBySize(12)
    local cw = Screen:scaleBySize(90)
    local ch = Screen:scaleBySize(130)
    local items = recentList(8)

    local header = LeftContainer:new{
        dimen = Geom:new{ w = w, h = Screen:scaleBySize(28) },
        TextWidget:new{
            text = "  " .. _("最近阅读"),
            face = Font:getFace("cfont", 18),
            bold = true,
        },
    }

    local row = HorizontalGroup:new{}
    table.insert(row, HorizontalSpan:new{ width = pad })
    if #items == 0 then
        table.insert(row, TextWidget:new{
            text = _("暂无记录 · 去书库打开一本书"),
            face = Font:getFace("xx_smallinfofont", 14),
            fgcolor = Blitbuffer.gray(0.5),
        })
    else
        for i, item in ipairs(items) do
            table.insert(row, coverCell(ctx, item, cw, ch))
            if i < #items then
                table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
            end
        end
    end

    local h = Screen:scaleBySize(28) + ch + Screen:scaleBySize(44)
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            row,
        },
    }
end

return M
