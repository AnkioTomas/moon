---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。
--- 对应表 tocs：目录缓存

---@class Toc
---@field book_key string PRIMARY KEY
---@field source_id string
---@field fetched_at integer 拉取时间戳
---@field chapters string JSON 编码的章节列表
---@field raw string|nil JSON 编码的原始目录数据
