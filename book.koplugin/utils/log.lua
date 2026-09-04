--[[--
Book 独立文件日志。

首次加载时清空上次运行的日志；后续日志积攒 10 条后经
SimpleJob 批量追加到 $DATA/.moon/book.log，不经过 KOReader logger。

@module koplugin.book.utils.log
--]]

local Paths = require("utils.paths")
local Settings = require("utils.settings")

local Log = {}
local BATCH_SIZE = 10
local started = false
local log_path
local buffer = {}
local flush_pending = false
local flush_requested = false

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

---@param batch string[]
---@return boolean
local function writeBatch(batch)
    local file = io.open(log_path, "a")
    if not file then return false end
    local ok, wrote = pcall(file.write, file, table.concat(batch))
    local closed, close_err = file:close()
    return ok and wrote ~= nil and closed ~= nil, close_err
end

local scheduleFlush

---@param batch string[]
local function restoreBatch(batch)
    local queued = buffer
    buffer = {}
    for i = 1, #batch do buffer[#buffer + 1] = batch[i] end
    for i = 1, #queued do buffer[#buffer + 1] = queued[i] end
end

scheduleFlush = function(force)
    if flush_pending then
        if force then flush_requested = true end
        return
    end
    if #buffer == 0 or not start() then return end
    local batch = buffer
    buffer = {}
    flush_pending = true

    local function complete(ok)
        flush_pending = false
        if not ok then
            restoreBatch(batch)
            flush_requested = false
            return
        end
        local force_next = flush_requested
        flush_requested = false
        if #buffer >= BATCH_SIZE or force_next then scheduleFlush(force_next) end
    end

    local ok = pcall(function()
        require("workers.simple_job").run(function()
            return writeBatch(batch)
        end, {
            on_done = complete,
            on_failed = function() complete(false) end,
        })
    end)
    if not ok then complete(false) end
end

local function write(level, ...)
    if not start() then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    buffer[#buffer + 1] = table.concat({
        os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] ",
        table.concat(parts, " "), "\n",
    })
    if #buffer >= BATCH_SIZE then scheduleFlush(false) end
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

--- 提交当前尾批；实际写盘仍在下一次 UI tick 的 SimpleJob 中完成。
---@return nil
function Log.flush()
    scheduleFlush(true)
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
