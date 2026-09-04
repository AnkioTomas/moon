--[[--
Book 独立文件日志。

首次加载时清空上次运行的日志；后续每条日志直接追加到
$DATA/.moon/book.log，不经过 KOReader logger。

@module koplugin.book.utils.log
--]]

local Paths = require("utils.paths")
local Settings = require("utils.settings")

local Log = {}
local started = false
local log_path

local function start()
    if started then return true end
    if type(Paths.ensureSettings) ~= "function" or type(Paths.logPath) ~= "function" then
        return false
    end
    local ok, path = pcall(function()
        Paths.ensureSettings()
        return Paths.logPath()
    end)
    if not ok then return false end
    local file = io.open(path, "w")
    if not file then return false end
    file:close()
    log_path = path
    started = true
    return true
end

local function write(level, ...)
    if not start() then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    local file = io.open(log_path, "a")
    if not file then return end
    file:write(os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] ", table.concat(parts, " "), "\n")
    file:close()
end

local function debugEnabled()
    local ok, enabled = pcall(function()
        return Settings.get("common").book_debug_enabled
    end)
    return ok and enabled == true
end

---@return string
function Log.path()
    return Paths.logPath()
end

---@return nil
function Log.start()
    start()
end

function Log.dbg(...)
    if debugEnabled() then
        write("DEBUG", ...)
    end
end

function Log.info(...)
    if debugEnabled() then
        write("INFO", ...)
    end
end

function Log.warn(...)
    write("WARN", ...)
end

function Log.error(...)
    write("ERROR", ...)
end

-- 兼容现有 KOReader logger.err 调用；迁移期间不改变调用方错误语义。
Log.err = Log.error

return Log
