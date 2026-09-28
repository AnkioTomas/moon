--[[--
主题文字：按字号角色（caption / body / title / hero）取字面与字号，颜色取灰度令牌。

  Text.line(theme, "title", "书名", { width = w })          -- 单行，超宽截断
  Text.box(theme, "body", long_text, w, { align = "center" })  -- 多行自动换行

opts.color 是灰度令牌（缺省 color.ink）；title / hero 默认加粗，opts.bold 可覆盖。

@module koplugin.book.ui.themes.widgets.text
--]]

local Blitbuffer = require("ffi/blitbuffer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("ui.themes.init")

local FACES = { caption = "xx_smallinfofont", body = "cfont", title = "cfont", hero = "cfont" }
local BOLD = { title = true, hero = true }

---@class BookThemeText
local Text = {}

---@param theme table 主题令牌
---@param role string caption/body/title/hero
---@return table face
function Text.face(theme, role)
    return Theme.face(FACES[role], theme.font[role])
end

---@param opts table
---@param role string
---@return boolean
local function bold(opts, role)
    if opts.bold ~= nil then return opts.bold end
    return BOLD[role] == true
end

--- 单行文字。
---@param theme table 主题令牌
---@param role string caption/body/title/hero
---@param text string
---@param opts table|nil width/color/bold
---@return table TextWidget
function Text.line(theme, role, text, opts)
    opts = opts or {}
    return TextWidget:new{
        text = text,
        face = Text.face(theme, role),
        bold = bold(opts, role),
        max_width = opts.width,
        fgcolor = Blitbuffer.Color8(opts.color or theme.color.ink),
    }
end

--- 多行文字；给 height 时超出部分可经 TextBoxWidget:scrollDown 翻页。
--- TextBoxWidget 会用底色铺满自身，放在非白表面上必须传 opts.bg。
---@param theme table 主题令牌
---@param role string caption/body/title/hero
---@param text string
---@param width number 物理像素
---@param opts table|nil color/bg/bold/align/height
---@return table TextBoxWidget
function Text.box(theme, role, text, width, opts)
    opts = opts or {}
    return TextBoxWidget:new{
        text = text,
        face = Text.face(theme, role),
        bold = bold(opts, role),
        width = width,
        height = opts.height,
        height_adjust = opts.height ~= nil,
        alignment = opts.align or "left",
        fgcolor = Blitbuffer.Color8(opts.color or theme.color.ink),
        bgcolor = Blitbuffer.Color8(opts.bg or theme.color.page),
    }
end

return Text
