--[[--
主体：一言。每次回到可见换一句，同一次可见期内重建不换。

@module koplugin.book.desktop.pages.home.hitokoto
--]]

local Geom = require("ui/geometry")
local Hitokoto = require("online.hitokoto")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookHomeHitokoto : BookHomeComponent
---@field text string|nil 上一句正文，下次抽句避重
---@field current table|nil 本次可见期的句子；暂停后清空
local M = {
    id = "hitokoto",
    label = _("一言"),
    icon = "format_quote",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

--- 署名一行：优先 source；否则 —— 作者 · 书名。
---@param quote table
---@return string
local function attribution(quote)
    if type(quote.source) == "string" and quote.source ~= "" then
        if quote.source:match("^——") then return quote.source end
        return "—— " .. quote.source
    end
    local author = type(quote.author) == "string" and quote.author or ""
    local title = type(quote.title) == "string" and quote.title or ""
    if author ~= "" and title ~= "" then return "—— " .. author .. " · " .. title end
    if author ~= "" then return "—— " .. author end
    if title ~= "" then return "—— " .. title end
    return ""
end

--- 返回一言内容高度；不吃剩余空间。
---@return BookHomeHeightSpec
function M:heightRange()
    local body = Text.line("body", "国")
    local caption = Text.line("caption", "国")
    local h = body:getSize().h * 2 + caption:getSize().h + Theme.px(Theme.current().space.sm)
    body:free()
    caption:free()
    return { height = h }
end

--- 随机选择与上一次不同的一言，并记录文本以供下次避重。
---@return { text: string, author: string, title: string }
function M:sample()
    local quote = Hitokoto.random(self.text)
    self.text = quote.text
    return quote
end

--- 正文最多两行（heightRange 只留了两行），署名靠右。
---@return table
function M:createWidget()
    self.current = self.current or self:sample()
    local quote = self.current
    local t = Theme.current()
    local width = self.opts.width
    local kids = {
        align = "left",
        Text.box("body", quote.text or "", width, { max_lines = 2 }),
    }
    local attr = attribution(quote)
    if attr ~= "" then
        local line = Text.line("caption", attr, { width = width, color = t.color.muted })
        kids[#kids + 1] = VerticalSpan:new{ width = Theme.px(t.space.xs) }
        kids[#kids + 1] = RightContainer:new{ dimen = Geom:new{ w = width, h = line:getSize().h }, line }
    end
    return VerticalGroup:new(kids)
end

function M:onDeactivate()
    self.current = nil
end

return M
