--[[--
首页时钟：大时间 + 日期 + 农历；恢复才拉日报与起分钟定时，内容未变不刷屏，暂停撤定时。
@module tests.desktop.pages.home.clock_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local myrl_cb
package.preload["online.myrl"] = function()
    return { fetch = function(_, _, cb) myrl_cb = cb; return { cancel = function() end } end }
end

local old_date = os.date
local now = { time = "10:20", sec = "20", day = "2026-09-10", w = "4" }
os.date = function(format, ...)
    if format == "%H:%M" then return now.time end
    if format == "%S" then return now.sec end
    if format == "%Y-%m-%d" then return now.day end
    if format == "%w" then return now.w end
    return old_date(format, ...)
end

local Clock = require("desktop.pages.home.clock")
local clock = Clock:new()
local slot = clock:build({ desktop = {} }, { width = 320, height = 96 })
Assert.eq(table.concat(Kit.texts(slot), "|"), "10:20|2026-09-10 星期四|--")
Assert.is_nil(myrl_cb, "构建不拉网")
Assert.is_true(Clock:heightRange().height > 0)

slot:paintTo(Kit.canvas(), 0, 10)
clock:activate()
Assert.len(Kit.scheduled, 1, "恢复起分钟定时")
Assert.eq(Kit.scheduled[1].delay, 41)
Assert.len(Kit.dirty, 0, "同一分钟不刷新")
myrl_cb({ lunar = "农历七月廿八", holiday = "中秋" })
Assert.eq(clock.extra.text, "农历七月廿八 · 中秋")
Assert.len(Kit.dirty, 1)
Assert.eq(Kit.dirty[1].region.y, 10, "只刷自己的矩形")

clock:pull()
myrl_cb({ lunar = "农历七月廿八", holiday = "中秋" })
Assert.len(Kit.dirty, 1, "缓存返回同内容新表也不刷新")

now.time = "10:21"
Kit.scheduled[1].fn()
Assert.eq(clock.time_widget.text, "10:21")
Assert.len(Kit.dirty, 2)
Assert.len(Kit.scheduled, 2, "到点续订下一分钟")

local tick = clock._tick
clock:deactivate()
Assert.eq(Kit.unscheduled[#Kit.unscheduled], tick, "暂停撤定时")
Assert.is_nil(clock._tick)
clock:activate()
Assert.not_nil(clock._tick, "暂停后可以直接恢复")
clock:destroy()
Assert.is_nil(clock._tick)
Assert.is_nil(clock.time_widget)

os.date = old_date
