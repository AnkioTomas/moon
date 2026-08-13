---@meta

--- 列表查询参数。
---@class BookListOpts
---@field page number|nil
---@field page_size number|nil
---@field search string|nil
---@field scope number|nil 书城搜索范围（wechat）
---@field series string|nil
---@field category string|nil
---@field favorite string|nil
---@field finished string|nil
---@field author string|nil

--- 列表响应。
---@class BookListResult
---@field count number|nil
---@field data Book[]|nil
