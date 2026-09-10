--[[--
主体：一言。与书摘同一块引言布局；resume 强制换一句。

@module koplugin.book.ui.desktop.home.components.hitokoto
--]]

local Hitokoto = require("online.hitokoto")
local Quote = require("ui.desktop.home.components.quote")
local _ = require("gettext")

---@class BookHomeHitokoto : BookHomeComponent
local M = {
    id = "hitokoto",
    label = _("一言"),
    icon = "format_quote",
}
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

function M:heightRange()
    return Quote.heightRange()
end

---@return { text: string, author: string, title: string }
function M:sample()
    local quote = Hitokoto.random(self.home.daily, self.text)
    self.text = quote.text
    return quote
end

---@param ctx BookDesktopCtx
---@param opts BookHomeBuildOpts
---@return table
function M:build(ctx, opts)
    local parts = Quote.build(self:sample(), opts.width, opts.height, opts.y)
    self.parts = parts
    self.desktop = ctx.desktop
    return { widget = parts.widget, height = parts.height }
end

function M:onResume()
    if not self.parts then return end
    Quote.paint(self.parts, self:sample())
    require("ui/uimanager"):setDirty(self.desktop, "ui", self.parts.region)
end

function M:onDestroy()
    self.parts = nil
    self.desktop = nil
    self.text = nil
end

return M
