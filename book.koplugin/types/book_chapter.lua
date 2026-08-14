---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。

--- 目录中的一章（capabilities.chapters）。
---@class BookChapter
---@field idx integer 连续章序号（1-based）
---@field source_idx string|nil 源端非连续章节号
---@field uid string|nil 源侧章节身份
---@field title string 章节标题
