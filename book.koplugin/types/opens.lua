---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。
--- 对应表 opens：最近打开记录（身份 = source_id + stable_id）

---@class Open
---@field source_id string PRIMARY KEY 组成部分
---@field stable_id string PRIMARY KEY 组成部分
---@field path string 本地打开路径（可变，随文件移动更新）
---@field chapter_idx integer|nil 章节序号
---@field last_open integer 最近打开时间戳
