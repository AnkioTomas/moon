--[[--
模拟器驱动（仅调试 / 文档截图用，不进插件包）。

临时拷到模拟器的 `koreader/patches/2-zz-emu-driver.lua`，重启模拟器生效；用完删掉。
每 0.3 秒读一次 /tmp/ko_cmd.lua，在 KOReader 主循环里执行，返回值写 /tmp/ko_out.txt
（首行 OK / ERR）。由 tools/emu.sh 投递命令。

全局 D：
  D.tap(x, y) / D.hold(x, y) / D.swipe(x, y, dir, dist)  合成手势
  D.shot(name)   截屏到 /tmp/moon-shots/<name>.png
  D.top()        窗口栈（栈顶在前），找弹窗名用
--]]

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Event = require("ui/event")
local Geom = require("ui/geometry")
local time = require("ui/time")

-- 默认联网。要故意断网测离线路径：MOON_EMU_ONLINE=0 ./run.sh
-- （旧默认断网是怕 LuaSocket×macOS 并发 getaddrinfo SIGSEGV；现在默认放开。）
if os.getenv("MOON_EMU_ONLINE") == "0" then
    local ok_nm, NM = pcall(require, "ui/network/manager")
    if ok_nm and NM then
        NM.isConnected = function() return false end
        if NM.isOnline then NM.isOnline = function() return false end end
    end
end

-- macOS 模拟器点击全部变成长按的根因：
-- SDL3.lua 用 CLOCK_MONOTONIC_COARSE 给触摸事件打戳；在 Darwin 上这是
-- CLOCK_MONOTONIC_RAW_APPROX，比 CLOCK_MONOTONIC / time.now() 慢约 500ms。
-- GestureDetector 却把触摸戳识别成 MONOTONIC，hold deadline = origin+500ms ≈ now，
-- 长按定时器几乎立刻触发，tap 永远出不来。clock_id=-1 让 Input:setTimeout 改走
-- time.now()+delay；并拦掉后续 probeClockSource，避免首触又探回 MONOTONIC。
-- （book.koplugin/main.lua 里也有同款；驱动先装时补丁更早生效。）
local function fixHoldClock()
    local ok_dev, Device = pcall(require, "device")
    if not ok_dev or not Device then return end
    local ok_gd, GD = pcall(require, "device/gesturedetector")
    if ok_gd and GD and not GD._moon_emu_hold_fixed then
        function GD:probeClockSource(_timev)
            self.clock_id = -1
        end
        GD._moon_emu_hold_fixed = true
    end
    local gd = Device.input and Device.input.gesture_detector
    if gd then gd.clock_id = -1 end
end
fixHoldClock()
UIManager:nextTick(fixHoldClock)

-- 默认路径给 tools/emu.sh。独立环境用 MOON_EMU_* 换一套，避免和已经开着的模拟器抢同一个命令文件。
local CMD = os.getenv("MOON_EMU_CMD") or "/tmp/ko_cmd.lua"
local OUT = os.getenv("MOON_EMU_OUT") or "/tmp/ko_out.txt"
local SHOTS = os.getenv("MOON_EMU_SHOTS") or "/tmp/moon-shots"
local BEAT = os.getenv("MOON_EMU_BEAT") or "/tmp/ko_emu_beat.txt"

_G.D = {}

function D.shot(name)
    UIManager:forceRePaint()
    Screen:shot(SHOTS .. "/" .. name .. ".png")
    return name
end

local function gesture(g)
    g.time = time.now()
    UIManager:sendEvent(Event:new("Gesture", g))
end

local function point(x, y)
    return Geom:new({ x = x, y = y, w = 0, h = 0 })
end

function D.tap(x, y)
    gesture({ ges = "tap", pos = point(x, y) })
end

function D.hold(x, y)
    gesture({ ges = "hold", pos = point(x, y) })
    gesture({ ges = "hold_release", pos = point(x, y) })
end

function D.swipe(x, y, dir, dist)
    gesture({ ges = "swipe", direction = dir, distance = dist or 200, pos = point(x, y) })
end

function D.top()
    local out = {}
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        out[#out + 1] = tostring(w.name or w.title or w.id or "?")
    end
    return table.concat(out, "\n")
end

local function poll()
    local ok_poll, err_poll = pcall(function()
        local beat = io.open(BEAT, "w")
        if beat then beat:write(tostring(os.time())); beat:close() end
        local f = io.open(CMD, "r")
        if f then
            local src = f:read("*a")
            f:close()
            os.remove(CMD)
            local fn, err = loadstring(src, "ko_cmd")
            local ok, res
            if fn then
                ok, res = xpcall(fn, debug.traceback)
            else
                ok, res = false, err
            end
            local o = io.open(OUT, "w")
            o:write((ok and "OK\n" or "ERR\n") .. tostring(res))
            o:close()
        end
    end)
    if not ok_poll then
        local e = io.open("/tmp/ko_emu_err.txt", "a")
        if e then e:write(tostring(err_poll) .. "\n"); e:close() end
    end
    UIManager:scheduleIn(0.3, poll)
end

os.execute("mkdir -p " .. SHOTS)
-- 补丁加载时 UIManager 任务队列可能还没转起来：先 nextTick 再进入轮询。
UIManager:nextTick(function()
    UIManager:scheduleIn(0.5, poll)
end)
