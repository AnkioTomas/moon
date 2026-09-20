--[[--
Book 独立文件日志。

同一天内重启继续追加日志，跨天首次启动时清空旧日志；后续日志积攒 10 条后经 nextTick
批量追加到 $DATA/.moon/book.log。

调试模式（book_debug_enabled）打开时：dbg/info 才写文件，且所有级别同步镜像到
KOReader `logger`（crash.log / 控制台），方便和系统日志一起看。

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
--- false=不可用；table=KOReader logger；nil=尚未探测。
local ko_logger

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
    local mode = "w"
    local attr = require("libs/libkoreader-lfs").attributes(path)
    if attr and os.date("%Y-%m-%d", attr.modification) == os.date("%Y-%m-%d") then
        mode = "a"
    end
    local file = io.open(path, mode)
    if not file then return false end
    file:close()
    log_path = path
    started = true
    return true
end

---@param batch string[]
---@return boolean, string|nil
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
        require("ui/uimanager"):nextTick(function()
            local write_ok = writeBatch(batch)
            complete(write_ok)
        end)
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

--- 调试模式下镜像到 KOReader logger；探测失败只记一次。
---@param method string dbg|info|warn|err
local function mirrorKo(method, ...)
    if ko_logger == false then return end
    if ko_logger == nil then
        local ok, mod = pcall(require, "logger")
        ko_logger = (ok and type(mod) == "table") and mod or false
        if not ko_logger then return end
    end
    local fn = ko_logger[method]
    if type(fn) == "function" then
        pcall(fn, ...)
    end
end

---@return string
function Log.path()
    return Paths.logPath()
end

---@return nil
function Log.start()
    start()
end

--- 提交当前尾批；实际写盘仍在下一次 UI tick 完成。
---@return nil
function Log.flush()
    scheduleFlush(true)
end

function Log.dbg(...)
    if not debugEnabled() then return end
    write("DEBUG", ...)
    mirrorKo("dbg", ...)
end

function Log.info(...)
    if not debugEnabled() then return end
    write("INFO", ...)
    mirrorKo("info", ...)
end

function Log.warn(...)
    write("WARN", ...)
    if debugEnabled() then
        mirrorKo("warn", ...)
    end
end

function Log.error(...)
    write("ERROR", ...)
    if debugEnabled() then
        mirrorKo("err", ...)
    end
end

return Log
