---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。

---@class BookChapterAnchor
---@field title string 章内目录标题
---@field depth integer 展示层级（1-based）

--- online / article 源目录中的一章。
---@class BookChapter
---@field idx integer 连续章序号（1-based）
---@field depth integer|nil 展示层级（1-based）
---@field anchors BookChapterAnchor[]|nil 章内目录节点
---@field toc_version integer|nil 目录缓存格式版本（仅首章携带）
---@field source_idx string|nil 源端非连续章节号
---@field uid string|nil 源侧章节身份
---@field title string 章节标题
---@field page number|nil KOReader 文档目录起始页
---@field xpointer string|nil KOReader 文档目录定位点
