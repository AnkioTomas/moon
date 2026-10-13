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

local CMD, OUT, SHOTS = "/tmp/ko_cmd.lua", "/tmp/ko_out.txt", "/tmp/moon-shots"

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
    UIManager:scheduleIn(0.3, poll)
end

os.execute("mkdir -p " .. SHOTS)
UIManager:scheduleIn(1, poll)
