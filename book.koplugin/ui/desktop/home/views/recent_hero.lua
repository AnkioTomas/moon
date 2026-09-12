--[[--
主体：当前阅读大卡片。书架读 catalog，不经 Home。

@module koplugin.book.ui.desktop.home.views.recent_hero
--]]

local BookInfo = require("ui.components.bookinfo")
local Catalog = require("book.catalog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
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

--- 返回当前组件的最小、首选和最大高度，供首页布局分配空间。
---@param _ctx table|nil 为保持组件接口一致保留的上下文，本实现不读取
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return BookHomeHeightRange range 首页布局使用的高度约束
function M:heightRange(_ctx, opts)
    local preferred = UI.sz(148)
    return {
        min = UI.sz(132),
        preferred = preferred,
        max = math.max(preferred, (opts and opts.height) or UI.sz(180)),
        grow = 2,
    }
end

--- 进入桌面图书馆并清除旧的筛选及分页状态。
---@param desktop table|nil 所属桌面实例
---@return nil
local function openLibrary(desktop)
    if not desktop or not desktop.switchTab then return end
    local library = desktop.library
    if library then
        library.filter = {}
        library.page = 1
        library.state = nil
    end
    desktop:switchTab("library")
end

--- 优先通过插件打开书籍；无插件实例时使用桌面详情入口。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param book Book 当前操作或展示的书籍数据
---@return nil
local function openBook(ctx, book)
    local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
    if plugin and plugin.openBook then
        plugin:openBook(book)
    elseif ctx.desktop and ctx.desktop.showDetail then
        ctx.desktop:showDetail(book)
    end
end

--- 从构建上下文或所属桌面取得当前数据源标识。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@return string|nil
local function sourceId(ctx)
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    return source and source.id
end

--- 取得最近阅读书籍并构建主角卡片；空结果时提供图书馆入口。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local h = opts.height
    local recent, _ignored_reading, err = Catalog.recentShelf(sourceId(ctx), 24)
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
        local tap = BookInfo.tappable(w, h, function()
            openLibrary(ctx.desktop)
        end)
        tap[1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = err or _("去图书馆挑一本 ›"),
                face = UI.face("cfont", 14),
                fgcolor = UI.muted(),
            },
        }
        body = tap
    end

    return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = h },
            body,
        }
end

return M
