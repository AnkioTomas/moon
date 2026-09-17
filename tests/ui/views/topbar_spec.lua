--[[--
ui.views.topbar 离线用例：状态项布局与图标档位。

@module tests.ui.views.topbar_spec
--]]

local Assert = require("support.assert")

local function widget()
    return {
        new = function(_, opts)
            opts.getSize = function(self) return self.dimen or { w = 0, h = 0 } end
            return opts
        end,
    }
end

local icon_calls = {}
local text_calls = {}
local powerd = {
    capacity = 100,
    charging = false,
    light = 37,
}

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/widget/container/framecontainer"] = widget
package.preload["ui/geometry"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/widget/container/leftcontainer"] = widget
package.preload["ui/widget/linewidget"] = widget
package.preload["ui/widget/overlapgroup"] = widget
package.preload["ui/widget/container/rightcontainer"] = widget
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            text_calls[#text_calls + 1] = opts.text
            local text = tostring(opts.text or "")
            return {
                text = opts.text,
                setText = function(self, value)
                    self.text = value
                end,
                getSize = function(self)
                    local current = tostring(self.text or "")
                    return { w = #current * 8, h = 12 }
                end,
            }
        end,
    }
end
package.preload["ui/widget/verticalgroup"] = widget
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
        },
        powerd = powerd,
        hasBattery = function() return true end,
        hasFrontlight = function() return true end,
    }
end
package.preload["datetime"] = function()
    return {
        secondsToHour = function(_, twelve_hour)
            return twelve_hour and "1:23 PM" or "13:23"
        end,
    }
end
local wifi_on = false
package.preload["ui/network/manager"] = function()
    return {
        isWifiOn = function() return wifi_on end,
    }
end
package.preload["datastorage"] = function()
    return {
        getDataDir = function() return "/tmp/moon-data" end,
    }
end
package.preload["ffi/util"] = function()
    return {
        df = function()
            return 64 * 1000 * 1000 * 1000, 12 * 1000 * 1000 * 1000, 10 * 1000 * 1000 * 1000
        end,
    }
end
package.preload["util"] = function()
    return {
        -- 256 MiB 可用 / 1 GiB 总量（字节）
        calcFreeMem = function() return 256 * 1024 * 1024, 1024 * 1024 * 1024 end,
        getFriendlySize = function(bytes)
            if bytes >= 1000 * 1000 * 1000 then
                return string.format("%.1f GB", bytes / 1000 / 1000 / 1000)
            end
            if bytes >= 1000 * 1000 then
                return string.format("%.1f MB", bytes / 1000 / 1000)
            end
            return tostring(bytes) .. " B"
        end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        topBarH = function() return 40 end,
        pagePad = function() return 12 end,
        line = function() return 1 end,
        sz = function(n) return n end,
        face = function(name, size) return { name = name, size = size } end,
        rule = function() return 128 end,
    }
end
package.preload["ui.components.icon"] = function()
    return {
        label = function(opts)
            icon_calls[#icon_calls + 1] = { kind = "label", name = opts.name, text = opts.text }
            local label = {
                text = opts.text,
                setText = function(self, value)
                    self.text = value
                end,
            }
            local icon = {
                [1] = {
                    setText = function(_, name)
                        opts.name = name
                    end,
                },
            }
            return {
                icon = icon,
                label = label,
                getSize = function()
                    return { w = #tostring(label.text or "") * 8 + 20, h = 14 }
                end,
            }
        end,
        widget = function(opts)
            icon_calls[#icon_calls + 1] = { kind = "widget", name = opts.name }
            local tw = {
                text = opts.name,
                setText = function(self, value)
                    self.text = value
                    opts.name = value
                end,
            }
            return { tw, name = opts.name, getSize = function() return { w = 14, h = 14 } end }
        end,
    }
end
local library_mixed = false
local topbar_items = {}
package.preload["utils.settings"] = function()
    return {
        activeSourceId = function() return "moon" end,
        libraryMixed = function() return library_mixed end,
        get = function() return { home_topbar_items = topbar_items } end,
    }
end
local source_name = "书库"
package.preload["source.registry"] = function()
    return { meta = function() return { name = source_name } end }
end
local cache_status
local cache_watch_cb
local cache_watch_cancel = 0
local scheduled = {}
local unschedules = 0
local dirty = {}
package.preload["source.cache_queue"] = function()
    return {
        status = function() return cache_status end,
        watch = function(cb)
            cache_watch_cb = cb
            return { cancel = function() cache_watch_cancel = cache_watch_cancel + 1 end }
        end,
    }
end
package.loaded["ui/uimanager"] = nil
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn)
            scheduled[#scheduled + 1] = { delay = delay, fn = fn }
        end,
        unschedule = function()
            unschedules = unschedules + 1
        end,
        setDirty = function(_, widget, _, region)
            dirty[#dirty + 1] = { widget = widget, region = region }
        end,
    }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    isTrue = function(_, key)
        return key == "twelve_hour_clock"
    end,
}

function powerd:getCapacity()
    return self.capacity
end

function powerd:isCharging()
    return self.charging
end

function powerd:frontlightIntensity()
    return self.light
end

package.loaded["ui.views.topbar"] = nil
local TopBar = require("ui.views.topbar")
local bar = TopBar:new()

bar:updateView()

local rect = bar.source.rect
Assert.is_true(rect ~= nil)
-- idle 时刷新不占位：时钟 + gap + 源名
Assert.eq(rect.x, 12 + #"1:23 PM" * 8 + 8)
Assert.eq(rect.w, #"书库" * 8 + 20)
Assert.eq(rect.h, 40)
Assert.is_nil(bar.refresh.metric_widget)

Assert.eq(icon_calls[1].name, "source")
Assert.eq(icon_calls[2].name, "memory")
Assert.eq(icon_calls[2].text, "268.4 MB")
Assert.eq(icon_calls[3].name, "hard_drive")
Assert.eq(icon_calls[3].text, "10.0 GB")
Assert.eq(icon_calls[4].name, "wifi_off")
Assert.eq(icon_calls[5].name, "brightness_6")
Assert.eq(icon_calls[6].name, "battery_android_full")
Assert.eq(icon_calls[6].text, "100%")
Assert.contains(text_calls, "1:23 PM")

-- 有后台全本缓存任务时，顶栏显示实时进度。
cache_status = { state = "running", cached = 34, total = 35 }
icon_calls = {}
bar:updateView()
Assert.eq(icon_calls[3].name, "download")
Assert.eq(icon_calls[3].text, "缓存 34/35")
Assert.not_nil(bar.cache.rect)
cache_status = nil

local normal_levels = {
    { 0, "battery_android_0" },
    { 15, "battery_android_1" },
    { 29, "battery_android_2" },
    { 43, "battery_android_3" },
    { 58, "battery_android_4" },
    { 72, "battery_android_5" },
    { 86, "battery_android_6" },
}
for _, case in ipairs(normal_levels) do
    icon_calls = {}
    powerd.capacity = case[1]
    powerd.charging = false
    bar:updateView()
    Assert.eq(icon_calls[6].name, case[2])
end

local charging_levels = {
    { 20, "battery_charging_20_2" },
    { 30, "battery_charging_30_2" },
    { 50, "battery_charging_50_2" },
    { 60, "battery_charging_60_2" },
    { 80, "battery_charging_80_2" },
    { 81, "battery_android_bolt" },
}
for _, case in ipairs(charging_levels) do
    icon_calls = {}
    powerd.capacity = case[1]
    powerd.charging = true
    bar:updateView()
    Assert.eq(icon_calls[6].name, case[2])
end

-- 电量越界：图标与文字共用钳制后的值
icon_calls = {}
powerd.capacity = 150
powerd.charging = false
bar:updateView()
Assert.eq(icon_calls[6].name, "battery_android_full")
Assert.eq(icon_calls[6].text, "100%")

-- 用户隐藏的项目不创建，也不留下可点击区域。
topbar_items = { source = false, memory = false, battery = false }
icon_calls = {}
local hidden_source = bar.source
bar:updateView()
Assert.is_nil(bar.source)
Assert.is_nil(bar.memory)
Assert.is_nil(bar.battery)
Assert.eq(hidden_source.lifecycle.state, "Destroy")
Assert.not_nil(bar.clock)
Assert.not_nil(bar.refresh)
Assert.is_nil(bar.refresh.metric_widget)
Assert.eq(icon_calls[1].name, "hard_drive")
Assert.eq(icon_calls[2].name, "wifi_off")
Assert.eq(icon_calls[3].name, "brightness_6")

topbar_items = {}
icon_calls = {}
bar:updateView()
Assert.not_nil(bar.source)
Assert.eq(icon_calls[1].name, "source")

topbar_items = { source = false, memory = false, battery = false }
local skipped = TopBar:new()
skipped:updateView()
Assert.is_nil(skipped.source)
Assert.is_nil(skipped.memory)
Assert.is_nil(skipped.battery)
Assert.not_nil(skipped.clock)
Assert.not_nil(skipped.storage)
topbar_items = {}

-- df 失败：存储指标省略，不炸
package.loaded["ffi/util"] = nil
package.preload["ffi/util"] = function()
    return {
        df = function()
            return nil, "statvfs is not available"
        end,
    }
end
package.loaded["ui.views.topbar"] = nil
package.loaded["ui.views.topbar.storage"] = nil
TopBar = require("ui.views.topbar")
bar = TopBar:new()
icon_calls = {}
bar:updateView()
Assert.eq(icon_calls[1].name, "source")
Assert.eq(icon_calls[2].name, "memory")
Assert.eq(icon_calls[3].name, "wifi_off")

-- 顶栏自己管生命周期：心跳只脏时钟，不重画整条。
local topbar_paints, home_paints = 0, 0
local desktop = {
    lifecycle = { state = "Resume" },
    updateView = function() topbar_paints = topbar_paints + 1 end,
    updateView = function() topbar_paints = topbar_paints + 1 end,
    refreshHomeClock = function() home_paints = home_paints + 1 end,
}
cache_status = { state = "running", cached = 1, total = 10 }
cache_watch_cb = nil
bar = TopBar:new()
bar.desktop = desktop
bar:onCreate()
Assert.not_nil(bar.clock.metric_widget)
Assert.eq(bar.cache.metric_widget.label.text, "缓存 1/10")
bar.clock.metric_widget:setText("old")
bar:onResume()
Assert.eq(bar.lifecycle.state, "Resume")
Assert.eq(#scheduled, 4, "时钟 + 内存 120s + 存储 600s + 电池 600s")
Assert.is_true(scheduled[1].delay >= 1)
Assert.is_true(scheduled[1].delay <= 61)
Assert.eq(scheduled[2].delay, 120)
Assert.eq(scheduled[3].delay, 600)
Assert.eq(scheduled[4].delay, 600)
Assert.is_true(type(cache_watch_cb) == "function")
local before_tick_dirty = #dirty
scheduled[1].fn()
Assert.eq(topbar_paints, 0, "心跳不得整条顶栏重画")
Assert.eq(home_paints, 0, "首页时钟由首页组件自己驱动")
Assert.eq(bar.clock.metric_widget.text, "1:23 PM")
Assert.eq(#dirty, before_tick_dirty + 1)
Assert.eq(dirty[#dirty].widget, desktop)
Assert.eq(dirty[#dirty].region, bar.clock.rect)
Assert.eq(#scheduled, 5)

cache_status = { state = "running", cached = 2, total = 10 }
cache_watch_cb()
Assert.eq(bar.cache.metric_widget.label.text, "缓存 2/10")
Assert.eq(topbar_paints, 0, "队列进度不得整条重画")

local before_pause = unschedules
bar:onPause()
Assert.is_nil(bar.clock._tick)
Assert.is_nil(bar.memory._tick)
Assert.is_nil(bar.storage._tick)
Assert.is_nil(bar.battery._tick)
Assert.eq(unschedules, before_pause + 4)
Assert.eq(cache_watch_cancel, 1)

powerd.capacity = 50
powerd.charging = true
wifi_on = true
bar.clock.metric_widget:setText("old")
local before_resume_paints = topbar_paints
local before_dirty = #dirty
bar:onResume()
Assert.eq(topbar_paints, before_resume_paints, "onResume 不得整条重画")
Assert.eq(bar.clock.metric_widget.text, "1:23 PM")
Assert.eq(bar.battery.metric_widget.label.text, "50%")
Assert.eq(bar.wifi.metric_widget[1].text, "wifi")
Assert.is_true(#dirty > before_dirty)

local freed = 0
local old_top = { free = function() freed = freed + 1 end }
desktop[1] = { { {}, old_top, {} } }
desktop.lifecycle.uiReady = function(self) return self.state == "Resume" end
desktop.view = require("ui.view").attach(desktop)
desktop.view:registerRegion("topbar", desktop[1][1], 2, { x = 0, y = 0, w = 600, h = 36 })
bar:onEvent("topbar_changed")
Assert.eq(desktop[1][1][2], bar.widget, "设置事件整条重建顶栏")
Assert.eq(freed, 1)
Assert.eq(topbar_paints, before_resume_paints, "updateView 走换槽，不整页 Desktop:updateView")

source_name = "微信读书"
bar:onEvent("source_changed")
Assert.eq(bar.source.metric_widget.label.text, "微信读书")
Assert.eq(topbar_paints, before_resume_paints, "换源只改源名，不整页 Desktop:updateView")

wifi_on = false
bar:onEvent("NetworkDisconnected")
Assert.eq(bar.wifi.metric_widget[1].text, "wifi_off")

-- 刷新：idle 不占位；出现/消失各重排一次；滚动只脏自己。
Assert.is_nil(bar.refresh.metric_widget)
local idle_source_x = bar.source.rect.x
bar:onEvent("refresh_status", "running")
Assert.eq(bar.refresh.status, "running")
Assert.not_nil(bar.refresh.metric_widget)
Assert.eq(bar.refresh.metric_widget[1].text, "autorenew")
Assert.eq(bar.source.rect.x, idle_source_x + 14 + 8, "出现在最左，源名右移")
local spin = scheduled[#scheduled]
Assert.eq(spin.delay, 0.2)
local before_spin_x = bar.source.rect.x
spin.fn()
Assert.eq(bar.refresh.metric_widget._spin_angle, 90)
Assert.eq(bar.source.rect.x, before_spin_x, "滚动不得带动其它项")

bar:onEvent("refresh_status", { state = "ok", text = "完成" })
Assert.eq(bar.refresh.status, "ok")
Assert.eq(bar.refresh.metric_widget[1].text, "check")
Assert.eq(bar.refresh.metric_widget._spin_angle, 0)
Assert.eq(bar.source.rect.x, before_spin_x, "仍显示时不重排")
local reset = scheduled[#scheduled]
Assert.eq(reset.delay, 2)
reset.fn()
Assert.eq(bar.refresh.status, "idle")
Assert.is_nil(bar.refresh.metric_widget)
Assert.eq(bar.source.rect.x, idle_source_x, "隐藏后收回占位")

-- 设置关掉 refresh 仍必建
topbar_items = { refresh = false }
bar:onEvent("topbar_changed")
Assert.not_nil(bar.refresh)
topbar_items = {}

powerd.capacity = 20
powerd.charging = false
bar:onEvent("NotCharging")
Assert.eq(bar.battery.metric_widget.label.text, "20%")

powerd.light = 12
bar:onEvent("FrontlightStateChanged")
Assert.eq(bar.brightness.metric_widget.label.text, "12%")

bar:onPause()
Assert.eq(cache_watch_cancel, 2, "Pause 取消一次，Resume 重订后 Pause 再取消")
bar:onDestroy()
Assert.eq(bar.lifecycle.state, "Destroy")
Assert.eq(cache_watch_cancel, 2)
bar:onDestroy()
Assert.eq(cache_watch_cancel, 2, "Destroy 不再重复取消")

local payload = {}
local received = 0
local events = TopBar:new({
    clock = {
        onEvent = function(_, event, data)
            Assert.eq(event, "Changed")
            Assert.eq(data, payload)
            received = received + 1
        end,
    },
})
events:onEvent("Changed", payload)
Assert.eq(received, 1)
events.lifecycle.state = "Destroy"
events:onEvent("Changed", payload)
Assert.eq(received, 1)

-- Pause 时新开的孩子只 Create，不开工。
topbar_items = {}
local paused = TopBar:new()
paused.desktop = {
    lifecycle = { state = "Resume" },
}
paused:onCreate()
paused:onResume()
paused:onPause()
topbar_items = { clock = false }
paused:updateView()
Assert.is_nil(paused.clock)
topbar_items = {}
paused:updateView()
Assert.not_nil(paused.clock)
Assert.eq(paused.clock.lifecycle.state, "Create")
Assert.is_nil(paused.clock._tick)

-- Resume 时新开的孩子补到 Resume 并开工。
paused:onResume()
topbar_items = { clock = false }
paused:updateView()
topbar_items = {}
paused:updateView()
Assert.eq(paused.clock.lifecycle.state, "Resume")
Assert.not_nil(paused.clock._tick)

-- 混合模式：源名槽位整项拆掉（图标和文案都不留）。
source_name = "书库"
local mixed_bar = TopBar:new()
mixed_bar:updateView()
Assert.not_nil(mixed_bar.source)
library_mixed = true
mixed_bar:onEvent("source_changed")
Assert.is_nil(mixed_bar.source)
library_mixed = false
mixed_bar:onEvent("source_changed")
Assert.not_nil(mixed_bar.source)
Assert.eq(mixed_bar.source.metric_widget.label.text, "书库")

_G.G_reader_settings = previous_settings
