---@meta

--- 图书馆 / 书城列表查询参数。
--- 未使用的筛选项传 nil 或空串；源不支持的项可忽略。
---@class BookListOpts
---@field page number|nil 页码，从 1 起
---@field page_size number|nil 每页条数（须与网格容量一致）
---@field search string|nil 关键词搜索
---@field scope number|nil 书城搜索范围（wechat：0 全部 / 10 电子书 / 16 网文 / 14 听书 等）
---@field series string|nil 按系列筛选
---@field category string|nil 按标签筛选
---@field favorite string|nil 按分类 / 收藏筛选
---@field finished string|nil 按是否读完筛选（moon 列表参数）
---@field author string|nil 按作者筛选

--- 列表响应（图书馆 / 书城 / 最近阅读）。
---@class BookListResult
---@field count number|nil 符合条件的总条数（分页用）
---@field data Book[]|nil 本页书籍；无数据时为空表
