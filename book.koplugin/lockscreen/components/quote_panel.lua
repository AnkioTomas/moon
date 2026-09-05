--[[--
锁屏语句面板：一言 / 高亮共用绘制。

@module koplugin.book.lockscreen.components.quote_panel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Layout = require("lockscreen.layout")
local Text = require("utils.text")

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
    local rect = Layout.panel({
        position = position,
        wide = wide,
        screen_w = sw,
        screen_h = sh,
    })
    local font_size = wide and 34 or 30
    local text_w = rect.text_w
    local max_text_h = math.floor(sh * 0.55)
    local Render = require("lockscreen.render")
    local text_h = Render.measureText(text, text_w, font_size, true)
    while text_h > max_text_h and font_size > 22 do
        font_size = font_size - 2
        text_h = Render.measureText(text, text_w, font_size, true)
    end

    -- 极端长文在最小字号仍放不下时按 UTF-8 边界截断，不能覆盖出处。
    if text_h > max_text_h then
        local low, high, fitted = 0, #text, ""
        while low <= high do
            local mid = math.floor((low + high) / 2)
            local candidate = Text.truncateUtf8(text, mid) .. "…"
            local height = Render.measureText(candidate, text_w, font_size, true)
            if height <= max_text_h then
                fitted, text_h, low = candidate, height, mid + 1
            else
                high = mid - 1
            end
        end
        text = fitted
    end

    local quote_h = math.min(50, font_size + 16)
    local text_top = rect.pad + quote_h + 4
    local source_h = 22
    local gap = math.max(14, rect.pad)
    local panel_h = math.max(
        math.floor(sh * 0.32),
        text_top + text_h + gap + 1 + gap + source_h + rect.pad
    )
    panel_h = math.min(panel_h, math.floor(sh * 0.88))
    rect = Layout.panel({
        position = position,
        wide = wide,
        height = panel_h,
        screen_w = sw,
        screen_h = sh,
    })
    local text_x = rect.text_x
    local text_y = rect.y + text_top
    local rule_y = text_y + text_h + gap
    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = "“", x = text_x, y = rect.y + rect.pad,
            width = text_w, size = quote_h, bold = true, box = false, color = Blitbuffer.COLOR_GRAY_4,
        },
        {
            text = text, x = text_x, y = text_y,
            width = text_w, size = font_size, bold = true, box = false,
        },
        { kind = "rule", x = text_x, y = rule_y, width = text_w, height = 1, color = Blitbuffer.COLOR_GRAY_5 },
        {
            text = source, x = text_x, y = rule_y + gap,
            width = text_w, size = 16, align = "right", box = false, color = Blitbuffer.COLOR_GRAY_3,
        },
    }
end

return M
