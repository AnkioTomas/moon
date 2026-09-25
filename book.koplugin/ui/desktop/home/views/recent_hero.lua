--[[--
主体：当前阅读大卡片。书架读 catalog，不经 Home。

@module koplugin.book.ui.desktop.home.views.recent_hero
--]]

local BookInfo = require("ui.components.bookinfo")
local Catalog = require("book.catalog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local UI = require("ui.components.bookui")
local _ = require("gettext")

---@class BookHomeRecentHero : BookHomeComponent
local M = {
    id = "recent_hero",
    label = _("当前阅读"),
    icon = "auto_stories",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 主角卡内容高度。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = UI.sz(148) }
end

--- 通过插件打开书籍；离屏无插件实例时不响应。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param book Book 当前操作或展示的书籍数据
local function openBook(ctx, book)
    local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
    if plugin and plugin.openBook then
        plugin:openBook(book)
    end
end

--- 取得最近阅读书籍并构建主角卡片；空结果时提供图书馆入口。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local h = opts.height
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    local recent, _ignored_reading, err = Catalog.recentShelf(source and source.id, 24)
    local body

    if recent then
        local cover_w = math.floor(math.max(1, h - UI.sz(12)) * 2 / 3)
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
        body = M.libraryPrompt(ctx, w, h, err)
    end

    return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = h },
            body,
        }
end

--- 返回首页时重读最近书架，避免继续显示阅读前的主角书籍和进度。
function M:onResume()
    if self.widget then self:rebuild() end
end

return M
