--[[--
SQLite 专用常驻 Worker。

本模块只定义数据库执行域，不在主进程执行 SQL。构造器返回 runtime
实例；调用方通过 `request(op, args, cb)` 发请求。

支持的操作：
  query(sql, params) → { result = ..., nrows = ... }
  exec(sql, params)  → { ok = true }

@module koplugin.book.workers.db
--]]

local DB = {}

---@param args { sql: string, params: any[]|nil }
---@return table
local function query(args)
    local Base = require("utils.db.base")
    local conn, open_err = Base.open()
    if not conn then error(open_err or "database open failed") end
    local result, nrows = Base.query(args.sql, unpack(args.params or {}))
    return { result = result, nrows = nrows }
end

---@param args { sql: string, params: any[]|nil }
---@return table
local function exec(args)
    local Base = require("utils.db.base")
    local conn, open_err = Base.open()
    if not conn then error(open_err or "database open failed") end
    local ok, err = Base.exec(args.sql, unpack(args.params or {}))
    if not ok then error(err or "database exec failed") end
    return { ok = true }
end

-- fork 后不能复用主进程连接；首次 SQL 会在子进程中重新建立连接。
---@return nil
local function init()
    local Base = require("utils.db.base")
    Base.close()
end

DB.handlers = {
    query = query,
    exec = exec,
}
DB.init = init

return DB
