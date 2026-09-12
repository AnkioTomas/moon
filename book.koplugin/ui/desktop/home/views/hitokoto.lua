--[[--
主体：一言。与书摘同一块引言布局；resume 强制换一句。

@module koplugin.book.ui.desktop.home.views.hitokoto
--]]

local Hitokoto = require("online.hitokoto")
local Quote = require("ui.views.quote")
local _ = require("gettext")

---@class BookHomeHitokoto : BookHomeComponent
local M = {
    id = "hitokoto",
    label = _("一言"),
    icon = "format_quote",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 返回当前组件的最小、首选和最大高度，供首页布局分配空间。
---@return BookHomeHeightRange range 首页布局使用的高度约束
function M:heightRange()
    return Quote.heightRange()
end

--- 随机选择与上一次不同的一言，并记录文本以供下次避重。
---@return { text: string, author: string, title: string }
function M:sample()
    local quote = Hitokoto.random(self.text)
    self.text = quote.text
    return quote
end

--- 按指定尺寸创建一言视图并保存可原地更新的引言实例。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local parts = Quote:new{
        data = self:sample(),
        width = opts.width,
        height = opts.height,
    }
    local widget = parts:build()
    self.parts = parts
    self.desktop = ctx.desktop
    return widget
end

--- 恢复显示时重新抽取一言，更新引言并刷新内容区域。
---@return nil
function M:onResume()
    if not self.parts then return end
    self.parts:updateView(self:sample())
    self:dirty("content")
end

--- 清除引言实例、桌面引用和上一次文本。
---@return nil
function M:onDestroy()
    self.parts = nil
    self.desktop = nil
    self.text = nil
end

return M
