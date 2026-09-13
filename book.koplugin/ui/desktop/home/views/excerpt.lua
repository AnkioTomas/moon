--[[--
主体：书摘。全库随机高亮；空库回退一言。有身份时可点开书。

@module koplugin.book.ui.desktop.home.views.excerpt
--]]

local Highlights = require("book.highlights")
local Hitokoto = require("online.hitokoto")
local Quote = require("ui.views.quote")
local _ = require("gettext")

---@class BookHomeExcerpt : BookHomeComponent
local M = {
    id = "excerpt",
    label = _("书摘"),
    icon = "format_ink_highlighter",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 返回书摘引言内容高度；不吃剩余空间。
---@param _ctx table|nil
---@param opts table|nil
---@return BookHomeHeightSpec
function M:heightRange(_ctx, opts)
    return Quote.heightRange({ width = opts and opts.width })
end

--- 优先随机选择书摘，空库时回退一言，并记录书籍身份及文本。
---@return { text: string, author: string, title: string, source_id: string|nil, stable_id: string|nil }
function M:sample()
    local quote = Highlights.random(self.text) or Hitokoto.random(self.text)
    self.text = quote.text
    self.quote = quote
    return quote
end

--- 创建书摘引言；有书籍身份时增加打开该书的点击区域。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local quote = self:sample()
    local parts = Quote:new{
        data = quote,
        width = opts.width,
        height = opts.height,
    }
    local widget = parts:build()
    if quote.source_id and quote.stable_id then
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
                require("ui.desktop.detail").open(ctx.desktop, book)
            end
        end)
        tap[1] = widget
        widget = tap
    end
    self.parts = parts
    self.desktop = ctx.desktop
    return widget
end

--- 恢复显示时重新抽取书摘并更新引言区域。
---@return nil
function M:onResume()
    if not self.parts then return end
    self.parts:updateView(self:sample())
    self:dirty("content")
end

--- 清除引言实例、书籍身份及桌面引用。
---@return nil
function M:onDestroy()
    self.parts = nil
    self.desktop = nil
    self.text = nil
    self.quote = nil
end

return M
