--[[--
主题文字：按字号角色（caption / body / title / hero）取字面与字号。

  Text.line("title", "书名", { width = w })          -- 单行，超宽截断
  Text.box("body", long_text, w, { align = "center" })  -- 多行自动换行

opts.color 是颜色令牌；title / hero 默认强调色并加粗，opts.bold 可覆盖。

@module koplugin.book.ui.themes.widgets.text
--]]

local Blitbuffer = require("ffi/blitbuffer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("ui.themes")

local FACES = { caption = "xx_smallinfofont", body = "cfont", title = "cfont", hero = "cfont" }
local BOLD = { title = true, hero = true }

---@class BookThemeText
local Text = {}

--- 代理画布：colorblitFrom 强制走 RGB32，其余名字透传给真画布。
---
--- 原生单行文字只用灰度 colorblitFrom；仅本控件改走 RGB，不修改全局画布或原生控件。
--- 但插件会覆写 TextWidget:paintTo 并直接对收到的 bb 调别的 BlitBuffer 方法
--- （如 appearance 会调 colorblitFromRGB32），代理缺方法就会在绘制时抛错，
--- 被 guard 捕获后整屏文字一个字都画不出来。透传按名字缓存闭包，逐字绘制不重复分配。
---@param bb table
---@return table
local function tinted_canvas(bb)
    local forwarded = {}
    return setmetatable({
        getWidth = function() return bb:getWidth() end,
        colorblitFrom = function(_, ...) return bb:colorblitFromRGB32(...) end,
    }, {
        __index = function(_, key)
            local method = forwarded[key]
            if method == nil then
                local value = bb[key]
                if type(value) ~= "function" then return value end
                method = function(_, ...) return value(bb, ...) end
                forwarded[key] = method
            end
            return method
        end,
    })
end

---@param widget table
---@return table
function Text.tint(widget)
    if not Blitbuffer.isColor8(widget.fgcolor) then
        function widget:paintTo(bb, x, y)
            TextWidget.paintTo(self, tinted_canvas(bb), x, y)
        end
    end
    return widget
end

---@param role string caption/body/title/hero
---@return table face
function Text.face(role)
    return Theme.face(FACES[role], Theme.current().font[role])
end

---@param opts table
---@param role string
---@return boolean
local function bold(opts, role)
    if opts.bold ~= nil then return opts.bold end
    return BOLD[role] == true
end

--- 单行文字。
---@param role string caption/body/title/hero
---@param text string
---@param opts table|nil width/color/bold/face
---@return table TextWidget
function Text.line(role, text, opts)
    opts = opts or {}
    local theme = Theme.current()
    return Text.tint(TextWidget:new{
        text = text,
        face = opts.face or Text.face(role),
        bold = bold(opts, role),
        max_width = opts.width,
        fgcolor = Theme.color(opts.color or (BOLD[role] and theme.color.headings or theme.color.ink)),
    })
end

--- 多行文字；给 height 时超出部分可经 TextBoxWidget:scrollDown 翻页。
--- max_lines：高度随内容、最多这么多行，超出以省略号收尾。
--- TextBoxWidget 会用底色铺满自身，放在非白表面上必须传 opts.bg。
---@param role string caption/body/title/hero
---@param text string
---@param width number 物理像素
---@param opts table|nil color/bg/transparent/bold/face/align/height/ellipsis/max_lines
---@return table TextBoxWidget 放没放下看 getAllLineCount() > getVisLineCount()
function Text.box(role, text, width, opts)
    opts = opts or {}
    local theme = Theme.current()
    local ink = Theme.color(opts.color or (BOLD[role] and theme.color.headings or theme.color.ink))
    local bg = Theme.color(opts.bg or theme.color.page)
    local mask = opts.transparent or not Blitbuffer.isColor8(ink)
    local function build(height)
        local box = TextBoxWidget:new{
            text = text,
            face = opts.face or Text.face(role),
            bold = bold(opts, role),
            width = width,
            height = height,
            height_adjust = height ~= nil,
            alignment = opts.align or "left",
            height_overflow_show_ellipsis = (opts.ellipsis or opts.max_lines) and true or nil,
            -- 彩色字也用蒙版，避免原生非 xtext 渲染路径把字形转灰。
            fgcolor = mask and Blitbuffer.COLOR_WHITE or ink,
            bgcolor = mask and Blitbuffer.COLOR_BLACK or bg,
        }
        if mask then
            function box:paintTo(bb, x, y)
                self.dimen.x, self.dimen.y = x, y
                if not opts.transparent then
                    local paint = Blitbuffer.isColor8(bg) and bb.paintRect or bb.paintRectRGB32
                    paint(bb, x, y, self.width, self._bb:getHeight(), bg)
                end
                local paint = Blitbuffer.isColor8(ink) and bb.colorblitFrom or bb.colorblitFromRGB32
                paint(bb, self._bb, x, y, 0, 0, self.width, self._bb:getHeight(), ink)
            end
        end
        return box
    end
    local box = build(opts.height)
    if opts.max_lines and box:getAllLineCount() > opts.max_lines then
        local height = opts.max_lines * box:getLineHeight()
        box:free()
        box = build(height)
    end
    return box
end

return Text
