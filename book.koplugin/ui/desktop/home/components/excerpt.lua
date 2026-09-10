--[[--
主体：书摘。与一言同一块引言布局；全库随机，空库复用一言回退池。

@module koplugin.book.ui.desktop.home.components.excerpt
--]]

local Highlights = require("book.highlights")
local Hitokoto = require("online.hitokoto")
local Quote = require("ui.desktop.home.components.quote")
local _ = require("gettext")

---@class BookHomeExcerpt : BookHomeComponent
local M = {
    id = "excerpt",
    label = _("书摘"),
    icon = "format_ink_highlighter",
}
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

function M:heightRange()
    return Quote.heightRange()
end

---@return { text: string, author: string, title: string }
function M:sample()
    local quote = Highlights.random(self.text) or Hitokoto.random(nil, self.text)
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
