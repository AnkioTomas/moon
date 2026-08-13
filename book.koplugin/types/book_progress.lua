---@meta

--- 单本远端阅读进度（拉取结果）。
--- percent 一律 0–100；`updateProgress` 入参仍用 frac∈[0,1]。
--- 按章源用 chapter_* 定位；整本源可只用 percent / spine。
---@class BookProgress
---@field percent number 全书进度 0–100
---@field chapter_uid string|number|nil 源侧章节身份（如微信 chapterUid）
---@field chapter_idx number|nil 连续章序号（1-based，与 BookChapter.idx 对齐）
---@field spine number|nil 整本打开时的 spine / 分卷下标（无章时作回退）

--- getProgress 返回包装；失败走第二返回值 err，不用 code/msg。
---@class BookProgressResult
---@field data BookProgress|nil 进度体；无远端进度时可为 nil
