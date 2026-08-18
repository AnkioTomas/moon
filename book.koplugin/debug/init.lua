--[[--
KOReader 调试日志镜像：开启后把 logger DEBUG 及以上日志同步写入
$DATA/.moon/logs/koreader.log。

这里只启用 logger 的 DEBUG 级别，不调用 dbg:turnOn()，避免改变运行时行为。

@module koplugin.book.debug
--]]

local M = {}

local MAX_SIZE = 2 * 1024 * 1024
local installed = false

local function path()
    return require("utils.paths").root() .. "/logs/koreader.log"
end

local function write(level, ...)
    if require("utils.settings").get().debug_enabled ~= true then return end
    local paths = require("utils.paths")
    paths.ensureSettings()
    local lfs = require("libs/libkoreader-lfs")
    local logs_dir = paths.root() .. "/logs"
    if lfs.attributes(logs_dir, "mode") ~= "directory" then
        lfs.mkdir(logs_dir)
    end
    local log_path = path()
    local attr = lfs.attributes(log_path)
    if attr and (attr.size or 0) >= MAX_SIZE then
        os.remove(log_path .. ".old")
        os.rename(log_path, log_path .. ".old")
    end
    local f = io.open(log_path, "a")
    if not f then return end
    local values = { os.date("%Y-%m-%d %H:%M:%S"), level }
    for i = 1, select("#", ...) do values[#values + 1] = tostring(select(i, ...)) end
    f:write(table.concat(values, " "), "\n")
    f:close()
end

function M.apply()
    local settings = require("utils.settings").get()
    if settings.debug_enabled ~= true or installed then return end
    local logger = require("logger")
    logger:setLevel(logger.levels.dbg)
    for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
        local original = logger[level]
        logger[level] = function(...)
            local enabled = require("utils.settings").get().debug_enabled == true
            if not enabled and level == "dbg" then return end
            original(...)
            if enabled then write(level:upper(), ...) end
        end
    end
    installed = true
    write("INFO", "book debug log enabled")
end

function M.path()
    return path()
end

return M
