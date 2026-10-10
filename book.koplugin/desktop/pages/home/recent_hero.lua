--[[--
主体：当前阅读大卡片。书架读 catalog，不经 Home。

@module koplugin.book.desktop.pages.home.recent_hero
--]]

local Hero = require("ui.widgets.bookhero")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local Theme = require("ui.themes")
local _ = require("gettext")

---@class BookHomeRecentHero : BookHomeComponent
local M = {
    id = "recent_hero",
    label = _("当前阅读"),
    icon = "auto_stories",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

--- 主角卡内容高度。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = Theme.px(148) }
end

--- 取得最近阅读书籍并构建主角卡片；空结果时提供图书馆入口。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w, h = opts.width, opts.height
    local recent, reading, err = self:shelf()
    if not recent then return M.libraryPrompt(ctx, w, h, err) end
    -- hero 还返回高度。写进构造器会变成第二个子件，Show 事件把它当控件索引。
    local card = Hero.widget(ctx.plugin, ctx.source, recent, {
        width = w,
        pad = Theme.px(10),
        cover_width = math.floor(math.max(1, h - Theme.px(12)) * 2 / 3),
        show_parent = ctx.desktop,
        on_tap = function() M.openBook(ctx, recent) end,
    })
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        card,
    }
end

return M
