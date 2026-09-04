--[[--
主体：当前阅读大卡片。

@module koplugin.book.ui.desktop.home.components.recent_hero
--]]

local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local _ = require("gettext")

local M = {
    id = "recent_hero",
    label = _("当前阅读"),
    icon = "auto_stories",
}

function M.heightRange()
    return {
        min = UI.sz(132),
        preferred = UI.sz(148),
        max = UI.sz(180),
        grow = 2,
    }
end

---@param desktop table|nil
local function openLibrary(desktop)
    if not desktop or not desktop.switchTab then return end
    desktop.filter = {}
    desktop.page = 1
    desktop._library_state = nil
    desktop:switchTab("library")
end

---@param ctx table
---@param book Book
local function openBook(ctx, book)
    local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
    if plugin and plugin.openBook then
        plugin:openBook(book)
    elseif ctx.desktop and ctx.desktop.showDetail then
        ctx.desktop:showDetail(book)
    end
end

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local h = opts.height
    local recent = state.recent
    local body

    if recent then
        local cover_w = math.min(
            UI.sz(96),
            math.floor(math.max(1, h - UI.sz(12)) * 2 / 3)
        )
        local hero = BookInfo.hero(ctx.plugin, ctx.source, recent, {
            width = w,
            pad = UI.sz(10),
            cover_width = cover_w,
            show_parent = ctx.desktop,
            on_tap = function() openBook(ctx, recent) end,
        })
        body = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            hero,
        }
    else
        local tap = BookInfo.tappable(w, h, function()
            openLibrary(ctx.desktop)
        end)
        tap[1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = state.recent_err or _("去图书馆挑一本 ›"),
                face = UI.face("cfont", 14),
                fgcolor = UI.muted(),
            },
        }
        body = tap
    end

    return {
        widget = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = h },
            body,
        },
        height = h,
    }
end

return M
