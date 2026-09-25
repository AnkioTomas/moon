--[[--
主体：书摘。全库随机高亮；空库回退一言。有身份时可点开书。
引言布局、高度与 resume 换句继承一言（hitokoto.lua）。

@module koplugin.book.ui.desktop.home.views.excerpt
--]]

local Highlights = require("book.highlights")
local Hitokoto = require("online.hitokoto")
local HitokotoView = require("ui.desktop.home.views.hitokoto")
local _ = require("gettext")

---@class BookHomeExcerpt : BookHomeHitokoto
local M = setmetatable({
    id = "excerpt",
    label = _("书摘"),
    icon = "format_ink_highlighter",
}, HitokotoView)
M.__index = M

--- 优先随机选择书摘，空库时回退一言，并记录书籍身份及文本。
---@return BookExcerptQuote
function M:sample()
    local quote = Highlights.random(self.text) or Hitokoto.random(self.text)
    self.text = quote.text
    self.quote = quote
    return quote
end

--- 创建书摘引言；有书籍身份时增加打开该书的点击区域。
---@return table
function M:createWidget()
    local widget = HitokotoView.createWidget(self)
    local ctx, opts, quote = self.ctx, self.opts, self.quote
    if not (quote.source_id and quote.stable_id) then return widget end
    local BookInfo = require("ui.components.bookinfo")
    local tap = BookInfo.tappable(opts.width, opts.height, function()
        local quote = self.quote
        if not quote or not quote.source_id or not quote.stable_id then return end
        local book = require("db.book").get(quote.source_id, quote.stable_id)
        if not book then
            book = {
                source_id = quote.source_id,
                stable_id = quote.stable_id,
                title = quote.title,
                authors = quote.author,
            }
        end
        local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
        if plugin then
            require("book.open").book(plugin, book)
        elseif ctx.desktop then
            require("ui.desktop.detail").open(ctx.desktop, "library", book)
        end
    end)
    tap[1] = widget
    return tap
end

--- 清除引言实例、书籍身份及桌面引用。
function M:onDestroy()
    HitokotoView.onDestroy(self)
    self.quote = nil
end

return M
