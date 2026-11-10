--[[--
Book 独立文件日志。

同一天内重启继续追加日志，跨天首次启动时清空旧日志；后续日志积攒 10 条后经 nextTick
批量追加到 $DATA/.moon/book.log。

进程启动时 main.lua 调 `boot` 先写字符串 logo，再写一行版本、设备与启动模式。
info / warn / error 始终写入 book.log；dbg 为空操作（调用点可保留，避免把高频痕迹写进日志）。
不镜像到 KOReader `logger` / crash.log。

@module koplugin.book.utils.log
--]]

local Paths = require("utils.paths")

local Log = {}
local BATCH_SIZE = 10
local started = false
local log_path
local buffer = {}
local flush_pending = false
local flush_requested = false

local function start()
    if started then return true end
    Paths.ensureDir(Paths.root())
    local path = Paths.logPath()
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
    local wrote = file:write(table.concat(batch))
    local closed, close_err = file:close()
    return wrote ~= nil and closed ~= nil, close_err
end

---@param batch string[]
local function restoreBatch(batch)
    local queued = buffer
    buffer = {}
    for i = 1, #batch do buffer[#buffer + 1] = batch[i] end
    for i = 1, #queued do buffer[#buffer + 1] = queued[i] end
end

local function scheduleFlush(force)
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

    require("ui/uimanager"):nextTick(function()
        complete(writeBatch(batch))
    end)
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

--- 提交当前尾批；实际写盘仍在下一次 UI tick 完成。
function Log.flush()
    scheduleFlush(true)
end

--- 立刻同步写盘。只用于休眠 / 唤醒这类随时可能卡死、等不到下一次 UI tick 的节点。
function Log.flushSync()
    if flush_pending or #buffer == 0 or not start() then return end
    local batch = buffer
    buffer = {}
    if not writeBatch(batch) then restoreBatch(batch) end
end

--- 不带时间戳与级别前缀。只给启动 logo 用，避免新月图形的对齐被拆掉。
---@param text string
local function writeRaw(text)
    if not start() then return end
    if text == "" then return end
    if text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    buffer[#buffer + 1] = text
    if #buffer >= BATCH_SIZE then scheduleFlush(false) end
end

-- 月读新月标志（源自 logo.png 的弦月），字标按最宽行 37 列居中。
-- 长括号字符串，不经 write()，以免每行被加上时间戳前缀。
local BOOT_LOGO = [[
                 ▄▄
           ▄▄███████
        ▄▄█████████▀
      ▄██████████▀
    ▄███████████▀
   █████████████
  █████████████
 ██████████████
▄██████████████
████████████████▄
█████████████████▄
█████▀▀████████▀▀██▄
█████▄ ▄██████▄ ▄████▄▄         ▄████
██████████▄▄███████████████████████
▀██████████████████████████████████
 ████████████████████████████████
  ███████████████████████████████▀
   ████████████████████████████▀
    ▀████████████████████████▀
             月读 · Moon
]]

--- 启动横幅：先写字符串 logo，再写月读 / KOReader 版本、设备与启动模式。
--- logo 为原始块，元数据行仍走 BOOT，方便检索。
function Log.boot()
    writeRaw(BOOT_LOGO)
    write("BOOT", "moon", require("bookversion"), "koreader", require("version"):getShortVersion(),
        "device", require("device").model,
        "startup_mode", require("utils.mem").startupMode())
    Log.flush()
end

--- 空操作：高频痕迹（如耗时采样）不写 book.log。
function Log.dbg(...)
end

function Log.info(...)
    write("INFO", ...)
end

function Log.warn(...)
    write("WARN", ...)
end

function Log.error(...)
    write("ERROR", ...)
end

return Log
