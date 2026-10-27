--[[--
休眠 / 唤醒诊断。

- 每个节点同步写 book.log，卡死后长按重启也留得下。
- 上次没正常退出（崩溃 / 卡死 / 强制重启）时，下次启动记一条 WARN。
- 唤醒后挂看门狗：主循环被阻塞、该自动消失的锁屏还挂在屏幕上，都只记 WARN。
  看门狗不许关屏：它分不清「卡住的旧锁屏」和「用户刚上的新锁屏」，真卡住按电源键能救，
  它误关一次就是用户刚锁的屏没了。只留日志给人事后定位，关屏权归 KOReader 和用户。

@module koplugin.book.utils.wake
--]]

local Log = require("utils.log")
local Paths = require("utils.paths")

local Wake = {
    GRACE = 5, -- 唤醒后多久检查（秒），锁屏有自动关闭延时时再加上延时
    STALL = 2, -- 看门狗迟到超过多少秒算主循环被阻塞
}

local watchdog
local suspend_count = 0

local function marker()
    return Paths.root() .. "/.running"
end

--- 进程启动时调一次。
function Wake.boot()
    local path = marker()
    local f = io.open(path, "r")
    if f then
        f:close()
        Log.warn("wake: previous session did not exit cleanly (crash, hang or forced restart)")
    end
    f = io.open(path, "w")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") --[[@as string]])
        f:close()
    end
    Log.flushSync()
end

--- 正常退出时调。
function Wake.exit()
    os.remove(marker())
end

function Wake.suspend()
    suspend_count = suspend_count + 1
    Log.info("wake: suspend")
    Log.flushSync()
end

--- 锁屏是否该已自动关闭：延时为数字或 disable；点击 / 手势退出的锁屏本来就要停着。
local function shouldAutoClose()
    local delay = G_reader_settings:readSetting("screensaver_delay")
    return tonumber(delay) ~= nil or delay == "disable"
end

--- 每次唤醒调；wait 到点时检查主循环是否被阻塞、锁屏是否还挂着（只记日志，不关）。
function Wake.resume()
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    Log.info("wake: resume")
    Log.flushSync()
    if watchdog then UIManager:unschedule(watchdog) end
    local wait = (tonumber(G_reader_settings:readSetting("screensaver_delay")) or 0) + Wake.GRACE
    local armed_at = time.now()
    local cycle = suspend_count
    watchdog = function()
        watchdog = nil
        -- 唤醒后又睡下去了：屏幕上是新一轮的锁屏，还挂着是正常的，连日志都别记。
        if cycle ~= suspend_count then return end
        local late = time.to_s(time.now() - armed_at) - wait
        if late > Wake.STALL then
            Log.warn(string.format("wake: UI loop blocked ~%.1fs after resume", late))
        end
        local Device = require("device")
        if Device.screen_saver_mode and shouldAutoClose() then
            Log.warn("wake: screensaver still shown after resume")
        end
        Log.flushSync()
    end
    UIManager:scheduleIn(wait, watchdog)
end

--- 计时执行 fn，超过 ms 毫秒记 WARN（唤醒路径上的同步步骤用）。
---@param label string
---@param fn function
function Wake.timed(label, fn, ...)
    local Perf = require("utils.perf")
    local started_at = Perf.now()
    fn(...)
    local ms = Perf.elapsedMs(started_at)
    if ms >= 500 then
        Log.warn("wake: slow step", label, ms, "ms")
        Log.flushSync()
    end
end

return Wake
