---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。

--- 统一阅读位置（拉/推进度唯一形态）。
---@class ProgressPosition
---@field fraction number 全书比例 0..1，必填
---@field chapter_idx integer|nil 连续章序号（1-based）
---@field chapter_fraction number|nil 章内比例 0..1
---@field locator string|nil XPointer/CFI 等精确定位
