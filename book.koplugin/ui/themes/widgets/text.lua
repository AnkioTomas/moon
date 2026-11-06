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
        colorblitFrom = function(_self, ...) return bb:colorblitFromRGB32(...) end,
    }, {
        __index = function(_proxy, key)
            local method = forwarded[key]
            if method == nil then
                local value = bb[key]
                if type(value) ~= "function" then return value end
                method = function(_self, ...) return value(bb, ...) end
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
---@param size number|nil 逻辑字号，缺省用该角色的主题字号
---@return table face
function Text.face(role, size)
    return Theme.face(FACES[role], size or Theme.current().font[role])
end

---@param opts table
---@param role string
---@return boolean
local function bold(opts, role)
    if opts.bold ~= nil then return opts.bold end
    return BOLD[role] == true
end

---@param text string
---@param images table<string, { url: string, headers?: table<string, string> }>
---@return string
---@return table[]
local function inlineText(text, images)
    local Utils = require("utils.text")
    local out, slots, offset, pos = {}, {}, 0, 1
    for first, code, after in text:gmatch("()(%b[])()") do
        local before = text:sub(pos, first - 1)
        out[#out + 1] = before
        offset = offset + #Utils.chars(before)
        if images[code] then
            out[#out + 1] = "\227\128\128"
            slots[#slots + 1] = { pos = offset + 1, image = images[code], text = code }
            offset = offset + 1
        else
            out[#out + 1] = code
            offset = offset + #Utils.chars(code)
        end
        pos = after
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out), slots
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
        fgcolor = Theme.color(opts.color or (BOLD[role] and theme.color.accent or theme.color.ink)),
    })
end

--- 多行文字；给 height 时超出部分可经 TextBoxWidget:scrollDown 翻页。
--- max_lines：高度随内容、最多这么多行，超出以省略号收尾。
--- TextBoxWidget 会用底色铺满自身，放在非白表面上必须传 opts.bg。
---@param role string caption/body/title/hero
---@param text string
---@param width number 物理像素
---@param opts table|nil color/bg/transparent/bold/face/align/height/ellipsis/max_lines/inline_images
---@return table TextBoxWidget 放没放下看 getAllLineCount() > getVisLineCount()
function Text.box(role, text, width, opts)
    opts = opts or {}
    local slots
    if opts.inline_images then text, slots = inlineText(text, opts.inline_images) end
    local theme = Theme.current()
    local ink = Theme.color(opts.color or (BOLD[role] and theme.color.accent or theme.color.ink))
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
    if slots and #slots > 0 then
        local size = box.face.size
        for _idx, slot in ipairs(slots) do
            box[#box + 1] = require("ui.themes.widgets.image").widget{
                src = slot.image.url, headers = slot.image.headers, width = size, height = size,
                style = {}, alpha = true, stretch = true,
                fallback = Text.line("caption", slot.text, { width = size }),
            }
        end
        local paint, free = box.paintTo, box.free
        function box:paintTo(bb, x, y)
            paint(self, bb, x, y)
            for idx, slot in ipairs(slots) do
                local px, py, line_num = self:_getXYForCharPos(slot.pos)
                local line = self.vertical_string_list[self.virtual_line_num + line_num - 1]
                if py >= 0 and py + size <= self:getSize().h
                    and (not line.end_offset or slot.pos <= line.end_offset)
                    and slot.pos ~= line.idx_to_substitute_with_ellipsis then
                    self[idx]:paintTo(bb, x + px, y + py + math.floor((self:getLineHeight() - size) / 2))
                end
            end
        end
        function box:free(full)
            for _idx, image in ipairs(self) do image:free(full) end
            free(self, full)
        end
    end
    return box
end

return Text
