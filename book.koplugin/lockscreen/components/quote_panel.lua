--[[--
锁屏语句面板：一言 / 高亮共用绘制。

@module koplugin.book.lockscreen.components.quote_panel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Layout = require("lockscreen.layout")

local M = {}

-- quote 主体需要根据实际字体测量高度，不能套用固定普通面板高度。
--- 统一绘制引号、正文、分割线和出处。
---@param text string
---@param source string
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(text, source, position, wide)
    local sw, sh = Layout.portraitSize()
    local margin = math.floor(sw * 0.07)
    local panel_w = wide and (sw - margin * 2) or math.floor(sw * 0.5)
    local font_size = wide and 34 or 30
    local text_w = panel_w - margin * 2
    local max_text_h = wide and math.floor(sh * 0.52) or math.floor(sh * 0.5)
    local Render = require("lockscreen.render")
    local text_h = Render.measureText(text, text_w, font_size, true)
    while text_h > max_text_h and font_size > 24 do
        font_size = font_size - 2
        text_h = Render.measureText(text, text_w, font_size, true)
    end
    local top_space = math.floor(sh * 0.12)
    local bottom_space = math.floor(sh * 0.13)
    local panel_h = math.max(math.floor(sh * 0.32), text_h + top_space + bottom_space)
    panel_h = math.min(panel_h, math.floor(sh * 0.88))
    local rect = Layout.panel({
        position = position,
        wide = wide,
        height = panel_h,
        screen_w = sw,
        screen_h = sh,
    })
    local text_x = rect.x + margin
    local rule_y = rect.y + rect.h - math.floor(sh * 0.09)
    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = "“", x = text_x, y = rect.y + math.floor(sh * 0.025),
            width = text_w, size = 56, bold = true, box = false, color = Blitbuffer.COLOR_GRAY_4,
        },
        {
            text = text, x = text_x, y = rect.y + math.floor(sh * 0.11),
            width = text_w, size = font_size, bold = true, box = false,
        },
        { kind = "rule", x = text_x, y = rule_y, width = text_w, height = 1, color = Blitbuffer.COLOR_GRAY_5 },
        {
            text = source, x = text_x, y = rule_y + math.floor(sh * 0.025),
            width = text_w, size = 16, align = "right", box = false, color = Blitbuffer.COLOR_GRAY_3,
        },
    }
end

return M
