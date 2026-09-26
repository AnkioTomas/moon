--[[--
nightmode：夜间窗口判定、切换点调度、日出日落计算、只在昼夜交替时切换、定位落盘。
@module tests.nightmode_spec
--]]

local Assert = require("support.assert")

local DAY = 24 * 60
local display = { auto_night = "off", auto_night_from = 22 * 60, auto_night_to = 7 * 60 }
local home = { home_weather_city = " Shanghai " }
local saved = 0
package.loaded["utils.settings"] = {
    get = function(section) return section == "home" and home or display end,
    saveSection = function() saved = saved + 1 end,
}

local events, scheduled = {}, {}
package.loaded["ui/event"] = {
    new = function(_, name, arg) return { name = name, arg = arg } end,
}
package.loaded["ui/uimanager"] = {
    broadcastEvent = function(_, ev) events[#events + 1] = ev end,
    scheduleIn = function(_, d, fn) scheduled[fn] = d end,
    unschedule = function(_, fn) scheduled[fn] = nil end,
    nextTick = function(_, fn) fn() end,
}

local sensor_level = 0
local Device = {
    hasFrontlight = function() return true end,
    hasLightSensor = function() return true end,
    ambientBrightnessLevel = function() return sensor_level end,
}
package.loaded["device"] = Device

local lights = {}
package.loaded["ui.panel.desktop"] = {
    setLevel = function(kind, fraction)
        Assert.eq(kind, "brightness")
        lights[#lights + 1] = fraction
    end,
}

local weather_reply
package.loaded["online.weather"] = {
    fetch = function(_, args, cb)
        Assert.eq(args.city, "Shanghai", "天气地点要 trim 后传")
        cb(weather_reply)
        return { cancel = function() end }
    end,
}

package.loaded["nightmode"] = nil
local NightMode = require("nightmode")

do -- 夜间窗口：同日、跨零点、无夜晚、整天
    Assert.is_true(NightMode.isNight(23 * 60, 22 * 60, 7 * 60))
    Assert.is_true(NightMode.isNight(3 * 60, 22 * 60, 7 * 60))
    Assert.is_false(NightMode.isNight(7 * 60, 22 * 60, 7 * 60), "结束时刻已是白天")
    Assert.is_true(NightMode.isNight(22 * 60, 22 * 60, 7 * 60), "开始时刻已是夜晚")
    Assert.is_false(NightMode.isNight(12 * 60, 22 * 60, 7 * 60))
    Assert.is_true(NightMode.isNight(13 * 60, 12 * 60, 14 * 60))
    Assert.is_false(NightMode.isNight(15 * 60, 12 * 60, 14 * 60))
    Assert.is_false(NightMode.isNight(600, 600, 600), "from == to 没有夜晚")
    Assert.is_true(NightMode.isNight(0, 0, DAY))
    Assert.is_true(NightMode.isNight(DAY - 1, 0, DAY))
end

do -- 下一个切换点：最近的 from / to / 零点
    Assert.eq(NightMode.nextDelay(22 * 60 - 1, 30, 22 * 60, 7 * 60), 30)
    Assert.eq(NightMode.nextDelay(22 * 60, 0, 22 * 60, 7 * 60), 120 * 60, "开始后先等零点重算")
    Assert.eq(NightMode.nextDelay(60, 0, 22 * 60, 7 * 60), 6 * 60 * 60)
    Assert.eq(NightMode.nextDelay(DAY - 1, 59, 600, 600), 1, "至少 1 秒")
end

do -- 上海 2026-09-26（年内第 269 天，UTC+8），wttr.in 给 日出 05:45 / 日落 17:46
    local from, to = NightMode.sunWindow(269, 31.239, 121.504, 480)
    Assert.is_true(math.abs(from - (17 * 60 + 46)) <= 3, "日落 " .. from)
    Assert.is_true(math.abs(to - (5 * 60 + 45)) <= 3, "日出 " .. to)
end

do -- 极夜整天是夜，极昼没有夜
    local from, to = NightMode.sunWindow(355, 78.2, 15.6, 60)
    Assert.eq(from, 0)
    Assert.eq(to, DAY)
    from, to = NightMode.sunWindow(172, 78.2, 15.6, 120)
    Assert.eq(from, 0)
    Assert.eq(to, 0)
end

do -- 关闭：不切、不排程
    NightMode.tick()
    Assert.len(events, 0)
    Assert.is_nil(scheduled[NightMode.tick])
    Assert.is_nil(NightMode.window())
end

do -- 定时全天是夜：首次必切，同一状态不再切（保留用户手动切换）
    display.auto_night_from, display.auto_night_to = 0, DAY
    NightMode.setMode("schedule")
    Assert.eq(display.auto_night, "schedule")
    Assert.len(events, 1)
    Assert.eq(events[1].name, "SetNightMode")
    Assert.is_true(events[1].arg)
    Assert.not_nil(scheduled[NightMode.tick])
    NightMode.onResume()
    Assert.len(events, 1, "昼夜没交替不重复切")
    NightMode.onPause()
    Assert.is_nil(scheduled[NightMode.tick])
end

do -- 改规则后立即按新规则切
    display.auto_night_from, display.auto_night_to = 600, 600
    NightMode.setMode("schedule")
    Assert.len(events, 2)
    Assert.is_false(events[2].arg)
end

do -- 关闭后重新开启，即使状态相同也要切一次
    NightMode.setMode("off")
    Assert.len(events, 2)
    NightMode.setMode("schedule")
    Assert.len(events, 3)
end

do -- 定位成功落盘经纬度
    local ok, city
    saved = 0
    weather_reply = { latitude = 31.239, longitude = 121.504, city = "Pootung" }
    NightMode.locate(function(a, b) ok, city = a, b end)
    Assert.is_true(ok)
    Assert.eq(city, "Pootung")
    Assert.eq(display.auto_night_lat, 31.239)
    Assert.eq(display.auto_night_lon, 121.504)
    Assert.eq(saved, 1)
end

do -- 定位失败不动已有经纬度
    local ok
    saved = 0
    weather_reply = {}
    NightMode.locate(function(a) ok = a end)
    Assert.is_false(ok)
    Assert.eq(display.auto_night_lat, 31.239)
    Assert.eq(saved, 0)
end

do -- 日出日落模式按落盘经纬度出窗口
    NightMode.setMode("sun")
    local from, to = NightMode.window()
    Assert.not_nil(from)
    Assert.not_nil(to)
    Assert.not_nil(scheduled[NightMode.tick])
    NightMode.setMode("off")
end

do -- 自动亮度关闭：不读传感器、不设亮度
    NightMode.sense()
    Assert.is_nil(NightMode.lightSource())
    Assert.len(lights, 0)
    Assert.is_nil(scheduled[NightMode.sense])
end

do -- 有传感器：按档位查表，档位不变不重设（保留手动调节），30 秒轮询
    display.auto_light = true
    display.auto_light_levels = { 15, 35, 20, 0, 0 }
    display.auto_light_day, display.auto_light_night = 30, 10
    Assert.eq(NightMode.lightSource(), "sensor")
    sensor_level = 1
    NightMode.sense()
    Assert.len(lights, 1)
    Assert.eq(lights[1], 0.35)
    Assert.eq(scheduled[NightMode.sense], 30)
    NightMode.onResume()
    Assert.len(lights, 1, "档位没变不重设")
    sensor_level = 3
    NightMode.sense()
    Assert.eq(lights[2], 0, "明亮关灯")
    NightMode.applyLight()
    Assert.len(lights, 3, "改了设置立刻按当前档位重设")
    display.auto_night_from, display.auto_night_to = 0, DAY
    NightMode.setMode("schedule")
    Assert.len(lights, 3, "有传感器时昼夜切换不管亮度")
    NightMode.onPause()
    Assert.is_nil(scheduled[NightMode.sense])
    Assert.is_nil(scheduled[NightMode.tick])
    NightMode.setMode("off")
end

do -- 无传感器（Kobo 等没有 hasLightSensor 方法）：昼夜交替时设白天 / 夜间亮度
    lights = {}
    Device.hasLightSensor = nil
    Assert.is_false(NightMode.hasSensor())
    Assert.eq(NightMode.lightSource(), "phase")
    NightMode.setMode("schedule")
    Assert.len(lights, 1)
    Assert.eq(lights[1], 0.1, "全天是夜用夜间亮度")
    NightMode.sense()
    Assert.is_nil(scheduled[NightMode.sense], "无传感器不轮询")
    display.auto_light_night = 20
    NightMode.applyLight()
    Assert.eq(lights[2], 0.2, "改了设置立刻按当前昼夜重设")
    local switches = #events
    NightMode.applyLight()
    Assert.len(events, switches, "改亮度不重切夜间模式")
    display.auto_light = false
    NightMode.applyLight()
    Assert.len(lights, 3, "关闭后不设亮度")
    NightMode.setMode("off")
end

do -- 开关自动亮度：落盘并立即生效；无传感器又没开自动夜间模式时判定为不会生效
    lights, saved = {}, 0
    NightMode.setLight(true)
    Assert.is_true(display.auto_light)
    Assert.eq(saved, 1)
    Assert.is_true(NightMode.lightIdle(), "自动夜间模式关着，亮度无昼夜可跟")
    display.auto_night_from, display.auto_night_to = 0, DAY
    NightMode.setMode("schedule")
    Assert.is_false(NightMode.lightIdle())
    Assert.eq(lights[#lights], 0.2, "开启后跟随当前昼夜")
    local count = #lights
    NightMode.setLight(false)
    Assert.is_false(display.auto_light)
    Assert.len(lights, count, "关闭不设亮度")
    Assert.is_false(NightMode.lightIdle())
    NightMode.setMode("off")
end

do -- 没有前光：不做任何亮度动作
    display.auto_light = true
    Device.hasFrontlight = function() return false end
    Assert.is_nil(NightMode.lightSource())
end
