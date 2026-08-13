---@meta

---@class BookChapter
---@field idx number 连续章序号（1-based），按章打开用
---@field title string|nil
---@field uid string|number|nil 源侧章节身份，拉正文用

---@class BookTocResult
---@field chapters BookChapter[]
