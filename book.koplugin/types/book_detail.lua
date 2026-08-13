---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。

--- 书籍详情（继承 Book 全部字段）。
--- 详情页 / 悬浮菜单简介区使用；列表接口不必填 intro。
---@class BookDetail : Book
---@field intro string|nil 简介正文（契约唯一简介字段）
