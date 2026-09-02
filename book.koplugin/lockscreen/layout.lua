--[[--
锁屏主体布局：九宫格位置 + 宽/窄屏 → 面板矩形。

所有主体组件共用此契约，禁止各自手写一套坐标。

@module koplugin.book.lockscreen.layout
--]]

local Device = require("device")
local _ = require("gettext")

local M = {}

-- 位置值只在这里维护，设置页和编排层共享同一份白名单。
local POSITIONS = {
    { id = "top-left", label = _("左上") }, { id = "top-center", label = _("上中") }, { id = "top-right", label = _("右上") },
    { id = "center-left", label = _("左中") }, { id = "center-center", label = _("居中") }, { id = "center-right", label = _("右中") },
    { id = "bottom-left", label = _("左下") }, { id = "bottom-center", label = _("下中") }, { id = "bottom-right", label = _("右下") },
}

local POSITION_BY_ID = {}
for _, position in ipairs(POSITIONS) do POSITION_BY_ID[position.id] = position end

--- 返回竖屏宽高；锁屏图片始终按竖屏尺寸生成。
---@return number, number
function M.portraitSize()
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    if w > h then
        return h, w
    end
    return w, h
end

--- 判断位置是否属于九宫格九个合法值。
---@param position string|nil
---@return boolean
function M.validPosition(position)
    return POSITION_BY_ID[position] ~= nil
end

--- 九宫格位置的设置页选项。
---@return {text: string, value: string}[]
function M.options()
    local options = {}
    for _, position in ipairs(POSITIONS) do
        options[#options + 1] = { text = position.label, value = position.id }
    end
    return options
end

--- 位置的显示名；非法值按居中显示。
---@param position string|nil
---@return string
function M.label(position)
    return (POSITION_BY_ID[position] or POSITION_BY_ID["center-center"]).label
end

--- 将位置字符串拆成垂直和水平两个方向；非法部分回到居中。
---@param position string|nil
---@return string vertical, string horizontal
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
--- 所有普通主体共用边距、内边距和圆角，避免各自漂移。
---@param opts { position: string|nil, wide: boolean|nil, height: number|nil, screen_w: number|nil, screen_h: number|nil }
---@return { x: number, y: number, w: number, h: number, pad: number, text_x: number, text_w: number, radius: number, wide: boolean }
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
        pad = pad,
        text_x = x + pad,
        text_w = panel_w - pad * 2,
        radius = math.max(8, math.floor(w * 0.02)),
    }
end

return M
