---@meta

--- 目录中的一章（capabilities.chapters）。
--- idx 给按章打开 / 跳转；uid 给源侧拉正文（如微信 reader）。
---@class BookChapter
---@field idx number 连续章序号（1-based），插件内打开与进度跳转用
---@field title string|nil 章节标题（目录菜单展示）
---@field uid string|number|nil 源侧章节身份；ensureChapter / 拉正文用

--- getToc 返回体。
---@class BookTocResult
---@field chapters BookChapter[] 已过滤不可读章后的有序列表
