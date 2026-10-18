--[[--
主体：书摘。全库随机高亮；空库回退一言。有身份时可点开书。
引言布局、高度与可见期换句继承一言（hitokoto.lua）。

@module koplugin.book.desktop.pages.home.excerpt
--]]

local Highlights = require("book.highlights")
local Hitokoto = require("online.hitokoto")
local HitokotoView = require("desktop.pages.home.hitokoto")
local _ = require("gettext")

---@class BookHomeExcerpt : BookHomeHitokoto
local M = setmetatable({
    id = "excerpt",
    label = _("书摘"),
    icon = "format_ink_highlighter",
}, HitokotoView)
M.__index = M

--- 优先随机选择书摘，空库时回退一言，并记录文本。
---@return BookExcerptQuote
function M:sample()
    local quote = Highlights.random(self.text) or Hitokoto.random(self.text)
    self.text = quote.text
    return quote
end

--- 书摘只用已缓存的一言做回退，不为它拉网。
function M:onActivate() end

--- 创建书摘引言；有书籍身份时整块可点开该书。
---@return table
function M:createWidget()
    local widget = HitokotoView.createWidget(self)
    local ctx, quote = self.ctx, self.current
    ---@cast quote BookExcerptQuote
    if not (quote.source_id and quote.stable_id) then return widget end
    return require("ui.themes.widgets.tap").wrap(widget, function()
        local book = require("book.books_db").get(quote.source_id, quote.stable_id) or {
            source_id = quote.source_id,
            stable_id = quote.stable_id,
            title = quote.title,
            authors = quote.author,
        }
        M.openBook(ctx, book)
    end)
end

return M
