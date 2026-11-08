--[[--
模拟器驱动：时钟适配仅限 Darwin 模拟器的当前输入实例。

@module tests.tools.emu_driver_spec
--]]

local Assert = require("support.assert")

local saved_driver = rawget(_G, "D")
local saved_getenv, saved_execute = os.getenv, os.execute
local offline = false
os.getenv = function(name)
    if name == "MOON_EMU_ONLINE" and offline then return "0" end
end
os.execute = function() return 0 end

package.loaded["ui/uimanager"] = { nextTick = function() end }
package.loaded["ui/event"] = {}
package.loaded["ui/geometry"] = {}
package.loaded["ui/time"] = {}

local Detector = {}
function Detector:probeClockSource(_timev) self.clock_id = 6 end
function Detector:resetClockSource() self.clock_id = nil end
local native_probe = Detector.probeClockSource
local network = {
    isConnected = function() return true end,
    isOnline = function() return true end,
}
package.loaded["ui/network/manager"] = network

for _idx, case in ipairs({
    { platform = "OSX", emulator = true },
    { platform = "Linux", emulator = true },
    { platform = "Windows", emulator = true },
    { platform = "OSX", emulator = false },
}) do
    local gd = setmetatable({ clock_id = 6 }, { __index = Detector })
    local other = setmetatable({ clock_id = 6 }, { __index = Detector })
    package.loaded["ffi"] = { os = case.platform }
    package.loaded["device"] = {
        screen = {},
        input = { gesture_detector = gd },
        isEmulator = function() return case.emulator end,
    }
    assert(loadfile("tools/emu_driver.lua"))()
    Assert.eq(Detector.probeClockSource, native_probe, "宿主类方法不变")
    other:resetClockSource()
    other:probeClockSource(0)
    Assert.eq(other.clock_id, 6, "其它输入实例不受影响")
    if case.platform == "OSX" and case.emulator then
        Assert.eq(gd.clock_id, -1)
        gd:resetClockSource()
        gd:probeClockSource(0)
        Assert.eq(gd.clock_id, -1, "休眠重置探测后仍用 UI 时间计算超时")
    else
        Assert.eq(gd.clock_id, 6)
        Assert.is_nil(rawget(gd, "probeClockSource"), "其它平台与真机不装补丁")
    end
end

offline = true
assert(loadfile("tools/emu_driver.lua"))()
Assert.is_false(network:isConnected())
Assert.is_false(network:isOnline())
package.loaded["ui/network/manager"] = nil
package.preload["ui/network/manager"] = function() error("network unavailable") end
Assert.errors(function() assert(loadfile("tools/emu_driver.lua"))() end, "network unavailable",
    "驱动依赖失败不能静默跳过")

os.getenv, os.execute = saved_getenv, saved_execute
_G.D = saved_driver
