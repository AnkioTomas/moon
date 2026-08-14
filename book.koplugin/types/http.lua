---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。
--- 对应表 http：HTTP 响应缓存

---@class Http
---@field key string PRIMARY KEY 缓存键
---@field value string 缓存内容
---@field expires integer 过期时间戳
---@field source_id string|nil
