--- 统一阅读位置（拉/推进度唯一形态）。

---@class ProgressPosition
---@field fraction number 全书比例 0..1，必填
---@field chapter_idx integer|nil 连续章序号（1-based）；部分源没有
---@field chapter_title string|nil 当前章节标题（跨源可读，不依赖 idx）
---@field chapter_fraction number|nil 章内比例 0..1
---@field page integer|nil 当前文档页码（1-based）
---@field total_pages integer|nil 当前文档总页数
---@field locator string|nil XPointer/CFI 等精确定位
---@field extra table|nil 源私有定位字段，原样往返本地库；跨源代码不得解读其内容
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
