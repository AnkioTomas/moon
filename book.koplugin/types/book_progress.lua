--- 统一阅读位置（拉/推进度唯一形态）。

---@class ProgressPosition
---@field fraction number 全书比例 0..1，必填
---@field chapter_idx integer|nil 连续章序号（1-based）
---@field chapter_fraction number|nil 章内比例 0..1
---@field locator string|nil XPointer/CFI 等精确定位
---@field updated_at integer|nil 待上传版本号，仅本地队列使用

local ProgressPosition = {}

--- fraction 钳制到 0..1。
---@param raw any
---@return number
function ProgressPosition.clampFraction(raw)
    local n = tonumber(raw)
    if not n then
        return 0
    end
    if n > 1 and n <= 100 then
        n = n / 100
    end
    if n < 0 then
        return 0
    end
    if n > 1 then
        return 1
    end
    return n
end

return ProgressPosition
