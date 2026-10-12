--[[--
桌面顶栏：各项是数据（read → text, icon），关掉的项与空读数不画；左组时钟 / 源名，右组指标；
有 tap 的项自己接点按，其余位置开快捷面板；读数签名变了才让桌面换顶栏；
定时器 / 订阅 Resume 挂、Pause 拆，设置变化重挂。
@module tests.desktop.topbar_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.home = {}
Kit.sections.desktop = {}

local powerd = { capacity = 100, charging = false }
function powerd:getCapacity() return self.capacity end
function powerd:isCharging() return self.charging end
local Device = require("device")
Device.powerd = powerd
function Device:hasBattery() return true end
function Device:hasFrontlight() return true end

local MoonSettings = require("utils.settings")
local mixed = false
local real_get = MoonSettings.get
MoonSettings.get = function(section)
    if section ~= "source" then return real_get(section) end
    return { library_mixed = mixed }
end

local avail_disk = 10 * 1000 * 1000 * 1000
require("ffi/util").df = function() return 0, 0, avail_disk end

package.preload["datetime"] = function()
    return { secondsToHour = function(_, twelve) return twelve and "1:23 PM" or "13:23" end }
end
package.preload["ui/network/manager"] = function() return { isWifiOn = function() return false end } end
package.preload["datastorage"] = function() return { getDataDir = function() return "/tmp/moon" end } end
package.preload["util"] = function()
    return {
        calcFreeMem = function() return 268400000 end,
        getFriendlySize = function(b) return string.format("%.1f GB", b / 1e9) end,
    }
end
package.preload["source.registry"] = function()
    return {
        activeId = function() return "moon" end,
        meta = function(id) return { id = id, name = "书库" } end,
    }
end
package.preload["features.panel.desktop"] = function() return { lightPercent = function() return 37 end } end
local panels = {}
package.preload["features.panel.native"] = function()
    return { show = function(id) panels[#panels + 1] = id end }
end
local dialogs = 0
package.preload["workers.ui.task_dialog"] = function()
    return {
        new = function(self) return setmetatable({}, { __index = { show = function() dialogs = dialogs + 1 end } }) end,
    }
end
local task, extra, watch_cb, watch_cancels = nil, {}, nil, 0
package.preload["workers.tasks"] = function()
    return {
        tasks = function()
            local out = { task }
            for _idx, t in ipairs(extra) do out[#out + 1] = t end
            return out
        end,
        watch = function(cb)
            watch_cb = cb
            return { cancel = function() watch_cancels = watch_cancels + 1 end }
        end,
    }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = { isTrue = function(_, key) return key == "twelve_hour_clock" end }

local Theme = require("ui.themes")
local TopBar = require("desktop.topbar")

local picks, swaps = 0, 0
local desktop = { settings = { source = { pickActive = function() picks = picks + 1 end } } }
local bar = TopBar:new{ desktop = desktop }
function desktop:updateTopbar()
    swaps = swaps + 1
    self.root = bar:build(600)
end

local function texts() return table.concat(Kit.texts(desktop.root), "|") end
local function has(part) return texts():find(part, 1, true) ~= nil end

Assert.eq(TopBar.height(), Theme.px(Theme.current().control.height))

do -- 全部打开：左时钟 / 源，右内存 / 后台任务 / 存储 / Wi‑Fi / 亮度 / 电量；无任务时后台任务显示空闲
    desktop:updateTopbar()
    Assert.eq(texts(), "1:23 PM|source|书库|memory|0.3 GB|download|空闲|hard_drive|10.0 GB|wifi_off|brightness_6|37%|battery_android_full|100%")
end

do -- 点按：源名换源；其余位置开快捷面板（整条是外层点击区）
    local taps = Kit.taps(desktop.root)
    Assert.len(taps, 3, "外层整条 + 源名 + 后台任务")
    taps[2]:onTapThemeArea()
    Assert.eq(picks, 1)
    taps[3]:onTapThemeArea()
    Assert.eq(dialogs, 1, "空闲时也能点开任务列表")
    dialogs = 0
    taps[1]:onTapThemeArea()
    Assert.eq(panels[1], "desktop")
end

do -- 后台任务：执行中数量 / 未结束总数；点按开任务列表
    task = { kind = "cache", state = "running" }
    desktop:updateTopbar()
    Assert.is_true(has("download|1/1|hard_drive"))
    Assert.len(Kit.taps(desktop.root), 3)
    Kit.taps(desktop.root)[3]:onTapThemeArea()
    Assert.eq(dialogs, 1)
    local Cache = TopBar.find("cache")
    task = { kind = "sync", state = "waiting" }
    Assert.eq(Cache.read(), "0/1")
    extra = { { kind = "sync", state = "running" }, { kind = "cache", state = "retry_wait" }, { kind = "cache", state = "queued" } }
    Assert.eq(Cache.read(), "1/4", "退避 / 等网络 / 排队不算执行中")
    extra = {}
    task = nil
    local text, icon = Cache.read()
    Assert.eq(text, "空闲")
    Assert.eq(icon, "download")
end

do -- 电量档位：放电 0..6 / full，充电分档，越界钳制（图标与文字同值）
    local Battery = TopBar.find("battery")
    local cases = {
        { 0, false, "battery_android_0" }, { 15, false, "battery_android_1" }, { 50, false, "battery_android_3" },
        { 99, false, "battery_android_6" }, { 100, false, "battery_android_full" }, { 150, false, "battery_android_full" },
        { 10, true, "battery_charging_20_2" }, { 30, true, "battery_charging_30_2" }, { 45, true, "battery_charging_50_2" },
        { 60, true, "battery_charging_60_2" }, { 75, true, "battery_charging_80_2" }, { 95, true, "battery_android_bolt" },
    }
    for _, c in ipairs(cases) do
        powerd.capacity, powerd.charging = c[1], c[2]
        local text, icon = Battery.read()
        Assert.eq(icon, c[3], tostring(c[1]) .. (c[2] and " charging" or ""))
        Assert.eq(text, string.format("%d%%", math.min(100, c[1])))
    end
    powerd.capacity = nil
    Assert.is_nil(Battery.read(), "读不到电量不画")
    powerd.capacity, powerd.charging = 100, false
end

do -- 混合模式源名
    mixed = true
    desktop:updateTopbar()
    Assert.is_true(has("source|混合模式"))
    mixed = false
end

do -- 用户关掉的项不画、不留点击区；读不到的项（存储）省略
    Kit.sections.desktop.home_topbar_items = { source = false, memory = false, battery = false }
    avail_disk = nil
    desktop:updateTopbar()
    Assert.eq(texts(), "1:23 PM|download|空闲|wifi_off|brightness_6|37%")
    Assert.len(Kit.taps(desktop.root), 2, "外层整条 + 后台任务")
    Kit.sections.desktop.home_topbar_items = nil
    avail_disk = 10 * 1000 * 1000 * 1000
    desktop:updateTopbar()
end

do -- Resume：轮询项共用一个分钟对齐心跳，外加订阅；读数没变不换顶栏
    swaps = 0
    bar:activate()
    Assert.is_true(bar.active)
    Assert.len(Kit.scheduled, 1, "时钟 / 内存 / 存储 / 电池共用一个心跳")
    Assert.is_true(Kit.scheduled[1].delay >= 1 and Kit.scheduled[1].delay <= 61)
    Assert.eq(type(watch_cb), "function")
    Assert.eq(swaps, 0)
    bar:activate()
    Assert.len(Kit.scheduled, 1, "重复 Resume 不重挂")
end

do -- 心跳：读数变了才换顶栏，并续约下一跳
    local tick = Kit.scheduled[1]
    tick.fn()
    Assert.eq(swaps, 0)
    Assert.len(Kit.scheduled, 2)
    powerd.capacity = 80
    tick.fn()
    Assert.eq(swaps, 1)
    Assert.is_true(has("80%"))
    task = { kind = "cache", state = "running" }
    watch_cb()
    Assert.eq(swaps, 2)
    Assert.is_true(has("download|1/1"))
    task = nil
end

local Event = require("ui/event")
local function broadcast(name) return desktop.root:handleEvent(Event:new(name)) end

do -- KOReader 广播沿树到顶栏控件：电源 / 网络 / 前光重读且不截断；无关事件忽略
    powerd.charging = true
    Assert.is_nil(broadcast("Unrelated"))
    Assert.eq(swaps, 2)
    Assert.is_nil(broadcast("Charging"), "不能吞掉，同层底栏还要收")
    Assert.eq(swaps, 3)
    Assert.is_true(has("battery_charging_80_2"))
    bar:onEvent("Charging")
    Assert.eq(swaps, 3, "onEvent 只管应用事件")
end

do -- 设置变化：拆掉重挂（关掉的项不再订阅）
    local before = #Kit.scheduled
    Kit.sections.desktop.home_topbar_items = { memory = false, cache = false }
    bar:onEvent("topbar_changed")
    Assert.len(Kit.unscheduled, 1)
    Assert.eq(watch_cancels, 1)
    Assert.eq(#Kit.scheduled - before, 1, "仍有轮询项，重挂一个心跳")
    Assert.eq(swaps, 4, "内存与任务项消失，签名变化")
end

do -- 轮询项全关：不挂心跳
    local before = #Kit.scheduled
    Kit.sections.desktop.home_topbar_items = { clock = false, memory = false, storage = false, battery = false }
    bar:onEvent("topbar_changed")
    Assert.len(Kit.unscheduled, 2)
    Assert.eq(#Kit.scheduled, before, "只剩事件驱动的项")
    Kit.sections.desktop.home_topbar_items = { memory = false, cache = false }
    bar:onEvent("topbar_changed")
    Assert.eq(#Kit.scheduled - before, 1)
end

do -- Pause：全部拆掉；之后心跳 / 事件不换顶栏
    bar:deactivate()
    Assert.is_false(bar.active)
    Assert.len(Kit.unscheduled, 3)
    local swaps_before = swaps
    powerd.capacity = 20
    broadcast("Charging")
    bar:refresh()
    Assert.eq(swaps, swaps_before)
    bar:onEvent("topbar_changed")
    Assert.is_false(bar.active, "暂停中改设置不重挂")
end

_G.G_reader_settings = previous_settings
return true
