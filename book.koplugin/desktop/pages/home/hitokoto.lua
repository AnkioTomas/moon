--[[--
主体：一言。每次回到可见换一句，同一次可见期内重建不换。

@module koplugin.book.desktop.pages.home.hitokoto
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Hitokoto = require("online.hitokoto")
local CenterContainer = require("ui/widget/container/centercontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local MoonSettings = require("utils.settings")
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
    style_key = "home_hitokoto_style",
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

-- 风格表：顺序即设置页顺序；高度不随风格变，布局不用重排。
local STYLES = {
    { id = "plain", label = _("默认") },
    { id = "center", label = _("居中") },
    { id = "bar", label = _("竖线") },
    { id = "mark", label = _("引号") },
}

---@return string
function M:style()
    local id = MoonSettings.get("desktop.pages.home")[self.style_key]
    for _idx, style in ipairs(STYLES) do
        if style.id == id then return id end
    end
    return "plain"
end

--- 编辑态设置：选引言风格。
---@param desktop BookDesktop
function M:showSettings(desktop)
    local current = self:style()
    local items = {}
    for _idx, style in ipairs(STYLES) do
        items[#items + 1] = {
            text = (style.id == current and "✓ " or "") .. style.label,
            callback = function()
                local home = MoonSettings.get("desktop.pages.home")
                home[self.style_key] = style.id
                MoonSettings.save("desktop.pages.home", home)
                desktop:onEvent("home_refresh")
            end,
        }
    end
    require("ui.themes.widgets.sheet"):new{ title = self.label, items = items }:show()
end

--- 正文（最多两行，heightRange 只留了两行）+ 署名，按风格排版。
---@return table
function M:createWidget()
    self.current = self.current or self:sample()
    local quote = self.current
    local t = Theme.current()
    local width = self.opts.width
    local style = self:style()
    local attr = attribution(quote)
    local gap = Theme.px(t.space.sm)

    -- 左侧留出装饰（竖线 / 引号）后的正文宽度
    local lead
    if style == "bar" then
        lead = LineWidget:new{ dimen = Geom:new{ w = Theme.px(2), h = 1 }, background = Blitbuffer.Color8(t.color.rule) }
    elseif style == "mark" then
        lead = Text.line("title", "“", { color = t.color.faint })
    end
    local lead_w = lead and (lead:getSize().w + gap) or 0
    local inner = width - lead_w
    local align = style == "center" and "center" or "left"

    local kids = { align = "left", Text.box("body", quote.text or "", inner, { max_lines = 2, align = align }) }
    if attr ~= "" then
        local line = Text.line("caption", attr, {
            width = inner, color = t.color.muted, bold = style == "center" or nil,
        })
        kids[#kids + 1] = VerticalSpan:new{ width = Theme.px(t.space.xs) }
        local container = style == "center" and CenterContainer or RightContainer
        kids[#kids + 1] = container:new{ dimen = Geom:new{ w = inner, h = line:getSize().h }, line }
    end
    local block = VerticalGroup:new(kids)
    if not lead then return block end
    if style == "bar" then lead.dimen.h = block:getSize().h end
    return HorizontalGroup:new{ align = "top", lead, HorizontalSpan:new{ width = gap }, block }
end

--- 组件在页上才拉一言；没放一言组件的用户不产生后台任务。
function M:onActivate()
    Hitokoto:ensure()
end

function M:onDeactivate()
    self.current = nil
end

return M
