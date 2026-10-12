--[[--
锁屏语句面板：白底 panel + 左侧引号 + 正文 + 右下署名，全部是 render 文字块。

@module koplugin.book.features.lockscreen.components.quote_panel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Layout = require("features.lockscreen.layout")
local Text = require("utils.text")

local M = {}

local MARK_SIZE, ATTR_SIZE = 28, 16

--- 长文先降字号，最小字号仍超高时按 UTF-8 边界截断加省略号。
---@param text string
---@param width number
---@param size number 起始字号
---@param min_size number
---@param max_h number
---@return string text, number size, number text_h
function M.fit(text, width, size, min_size, max_h)
    local Render = require("features.lockscreen.render")
    local text_h = Render.measureText(text, width, size, true)
    while text_h > max_h and size > min_size do
        size = size - 2
        text_h = Render.measureText(text, width, size, true)
    end
    if text_h <= max_h then return text, size, text_h end
    local low, high, fitted = 0, #text, ""
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = Text.truncateUtf8(text, mid) .. "…"
        local height = Render.measureText(candidate, width, size, true)
        if height <= max_h then
            fitted, text_h, low = candidate, height, mid + 1
        else
            high = mid - 1
        end
    end
    return fitted, size, text_h
end

--- 正文和出处；面板高度随内容，内容在面板内垂直居中。
---@param text string
---@param source string 空串不画署名；未带「——」前缀的补上
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(text, source, position, wide)
    local Render = require("features.lockscreen.render")
    local _w, sh = Layout.portraitSize()
    local rect = Layout.panel({ position = position, wide = wide })
    -- 引号列宽取引号字号的行高，正文让出这一列和一个间隙。
    local mark_w = Render.measureText("“", rect.text_w, MARK_SIZE)
    local gap = math.floor(rect.pad / 2)
    local body_w = rect.text_w - mark_w - gap
    -- 极端长文在最小字号仍放不下时截断，不能覆盖出处。
    local body, size, body_h = M.fit(text, body_w, wide and 34 or 30, 22, math.floor(sh * 0.55))
    local attr = source ~= "" and (source:match("^——") and source or "—— " .. source) or nil
    local attr_gap = math.max(14, rect.pad)
    local content_h = body_h + (attr and attr_gap + Render.measureText(attr, rect.text_w, ATTR_SIZE) or 0)

    local panel_h = math.min(math.max(math.floor(sh * 0.32), rect.pad * 2 + content_h), math.floor(sh * 0.88))
    rect = Layout.panel({ position = position, wide = wide, height = panel_h })
    local top = rect.y + math.floor((rect.h - content_h) / 2)
    local blocks = {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = "“", x = rect.text_x, y = top, width = mark_w, size = MARK_SIZE,
            box = false, color = Blitbuffer.COLOR_GRAY_3,
        },
        { text = body, x = rect.text_x + mark_w + gap, y = top, width = body_w, size = size, box = false },
    }
    if attr then
        blocks[#blocks + 1] = {
            text = attr, x = rect.text_x, y = top + body_h + attr_gap, width = rect.text_w, size = ATTR_SIZE,
            align = "right", box = false, color = Blitbuffer.COLOR_GRAY_3,
        }
    end
    return blocks
end

return M
