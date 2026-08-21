--[[--
锁屏主体布局：九宫格位置 + 宽/窄屏 → 面板矩形。

所有主体组件共用此契约，禁止各自手写一套坐标。

@module koplugin.book.lockscreen.layout
--]]

local Device = require("device")

local M = {}

local POSITIONS = {
    ["top-left"] = true, ["top-center"] = true, ["top-right"] = true,
    ["center-left"] = true, ["center-center"] = true, ["center-right"] = true,
    ["bottom-left"] = true, ["bottom-center"] = true, ["bottom-right"] = true,
}

--- 竖屏宽高（锁屏强制竖屏出图）。
---@return number, number
function M.portraitSize()
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    if w > h then
        return h, w
    end
    return w, h
end

---@return string YYYY-MM-DD
function M.dayKey()
    return os.date("%Y-%m-%d")
end

---@param position string|nil
---@return boolean
function M.validPosition(position)
    return POSITIONS[position] == true
end

---@param position string|nil
---@return string, string vertical, horizontal
function M.parsePosition(position)
    local vertical, horizontal = tostring(position or "center-center"):match("^(%w+)%-(%w+)$")
    vertical = vertical or "center"
    horizontal = horizontal or "center"
    if vertical ~= "top" and vertical ~= "bottom" then
        vertical = "center"
    end
    if horizontal ~= "left" and horizontal ~= "right" then
        horizontal = "center"
    end
    return vertical, horizontal
end

--- 计算主体面板矩形。
---@param opts { position: string|nil, wide: boolean|nil, height: number|nil, screen_w: number|nil, screen_h: number|nil }
---@return { x: number, y: number, w: number, h: number, margin: number, pad: number, text_x: number, text_w: number, font_size_hint: number, radius: number }
function M.panel(opts)
    opts = opts or {}
    local w = opts.screen_w
    local h = opts.screen_h
    if not w or not h then
        w, h = M.portraitSize()
    end
    local wide = opts.wide ~= false
    local margin = math.floor(w * 0.07)
    local panel_w = wide and (w - margin * 2) or math.floor(w * 0.5)
    local vertical, horizontal = M.parsePosition(opts.position)
    local panel_h = opts.height
    if not panel_h then
        panel_h = wide and math.floor(h * 0.72) or math.floor(h * 0.55)
    end
    panel_h = math.max(math.floor(h * 0.18), math.min(panel_h, math.floor(h * 0.92)))

    local x = horizontal == "left" and margin
        or horizontal == "right" and (w - margin - panel_w)
        or math.floor((w - panel_w) / 2)
    local y = vertical == "top" and margin
        or vertical == "bottom" and (h - margin - panel_h)
        or math.floor((h - panel_h) / 2)

    local pad = math.max(12, math.floor(w * 0.035))
    return {
        x = x,
        y = y,
        w = panel_w,
        h = panel_h,
        margin = margin,
        pad = pad,
        text_x = x + pad,
        text_w = panel_w - pad * 2,
        font_size_hint = wide and 34 or 30,
        radius = math.max(8, math.floor(w * 0.02)),
        wide = wide,
        screen_w = w,
        screen_h = h,
    }
end

return M
