--[[--
锁屏小票标题布局。

只处理显示文本，不修改书籍数据；测量函数由调用方注入，便于离线测试。

@module koplugin.book.lockscreen.title
--]]

local Text = require("utils.text")

local M = {}

--- 将标题压到单行；最小字号仍放不下时按 UTF-8 边界加省略号。
---@param text string
---@param width number
---@param size number
---@param min_size number
---@param measure fun(text: string, width: number, size: number): number
---@return string, number
function M.fitSingleLine(text, width, size, min_size, measure)
    text = tostring(text or "")
    width = math.max(1, math.floor(tonumber(width) or 1))
    size = math.max(1, math.floor(tonumber(size) or 1))
    min_size = math.max(1, math.min(size, math.floor(tonumber(min_size) or size)))

    local line_height = measure("M", width, size)
    while size > min_size and measure(text, width, size) > line_height do
        size = size - 1
        line_height = measure("M", width, size)
    end
    if measure(text, width, size) <= line_height then
        return text, size
    end

    local low, high, fitted = 0, #text, "…"
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = Text.truncateUtf8(text, mid) .. "…"
        if measure(candidate, width, size) <= line_height then
            fitted = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return fitted, size
end

return M
