--[[--
锁屏语句面板：白底 panel + 共享 Quote Widget。

@module koplugin.book.lockscreen.components.quote_panel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Layout = require("lockscreen.layout")
local Text = require("utils.text")

local M = {}

--- 绘制正文和出处（共享 UI 组件）。
---@param text string
---@param source string
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(text, source, position, wide)
    -- 延迟加载：避免 lockscreen 注册表 require 时拉进 KOReader Widget。
    local Quote = require("ui.views.quote")
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

    local line_em = 0.35
    local line_px = math.max(1, math.floor((1 + line_em) * font_size + 0.5))
    local lines = math.max(2, math.ceil(text_h / line_px))
    local quote_opts = {
        body_size = font_size,
        attr_size = 16,
        lines = lines,
        line_em = line_em,
        pad_x = 0,
        gap_attr = math.max(14, rect.pad),
    }
    local content_h = Quote.contentHeight(quote_opts)
    local panel_h = math.max(
        math.floor(sh * 0.32),
        rect.pad * 2 + content_h
    )
    panel_h = math.min(panel_h, math.floor(sh * 0.88))
    rect = Layout.panel({
        position = position,
        wide = wide,
        height = panel_h,
        screen_w = sw,
        screen_h = sh,
    })

    local inner_h = math.max(1, rect.h - rect.pad * 2)
    quote_opts.data = { text = text, source = source }
    quote_opts.width = text_w
    quote_opts.height = inner_h
    local widget = Quote:new(quote_opts):build()

    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            kind = "widget",
            widget = widget,
            x = rect.text_x,
            y = rect.y + rect.pad,
            width = text_w,
            height = inner_h,
        },
    }
end

return M
