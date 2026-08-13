---@meta

--- 远端阅读进度。percent ∈ 0–100；updateProgress 入参仍用 frac∈[0,1]。
---@class BookProgress
---@field percent number
---@field chapter_uid string|number|nil
---@field chapter_idx number|nil
---@field spine number|nil

---@class BookProgressResult
---@field data BookProgress|nil
