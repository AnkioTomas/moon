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
local powerd = { on = true, percent = 0 }
function powerd:isFrontlightOff() return not self.on end
local Device = {
    hasFrontlight = function() return true end,
    hasLightSensor = function() return true end,
    ambientBrightnessLevel = function() return sensor_level end,
    getPowerDevice = function() return powerd end,
}
package.loaded["device"] = Device

local lights = {}
package.loaded["ui.panel.desktop"] = {
    setLevel = function(kind, fraction)
        Assert.eq(kind, "brightness")
        lights[#lights + 1] = fraction
        -- 0 = 关灯；其余模拟设备量化误差（读回比设的高 1%）。
        powerd.on = fraction > 0
        powerd.percent = powerd.on and math.floor(fraction * 100 + 0.5) + 1 or 0
        package.loaded["nightmode"].onFrontlightChanged() -- KOReader 同步广播 FrontlightStateChanged
    end,
    lightPercent = function() return powerd.percent end,
}

local weather_reply, weather_fetches = nil, 0
package.loaded["online.weather"] = {
    iconKey = function(code) return code or "unknown" end,
    fetch = function(_, args, cb)
        weather_fetches = weather_fetches + 1
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

do -- 当地时区由天气给的当地日出反推：北京 +8，纽约 -4（夏令时），24 小时制也认，取不到返回 nil
    Assert.eq(NightMode.siteTz("06:06 AM", 270, 39.929, 116.388), 480)
    Assert.eq(NightMode.siteTz("06:06", 270, 39.929, 116.388), 480)
    Assert.eq(NightMode.siteTz("06:54 AM", 270, 40.71, -74.01), -240)
    Assert.eq(NightMode.siteTz("05:45 AM", 270, 0, 0), 0)
    Assert.eq(NightMode.siteTz("05:45 PM", 270, 0, 0), 720, "PM 加 12 小时")
    Assert.is_nil(NightMode.siteTz(nil, 270, 39.929, 116.388))
    Assert.is_nil(NightMode.siteTz("No sunrise", 270, 39.929, 116.388))
    Assert.is_nil(NightMode.siteTz("10:00 AM", 172, 78.2, 15.6), "极昼没有日出")
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
    weather_reply = { latitude = 31.239, longitude = 121.504, city = "Pootung", sunrise = "05:45 AM" }
    NightMode.locate(function(a, b) ok, city = a, b end)
    Assert.is_true(ok)
    Assert.eq(city, "Pootung")
    Assert.eq(display.auto_night_lat, 31.239)
    Assert.eq(display.auto_night_lon, 121.504)
    Assert.eq(display.auto_night_tz, 480)
    Assert.eq(saved, 1)
end

do -- 时钟拨成本地、时区停在美东的 Kindle：按当地时区出窗口，不被设备时区带偏半天
    local real_date = os.date
    os.date = function(fmt, t)
        if fmt == "!*t" then return real_date("!*t", (t or os.time()) + 4 * 3600) end
        return real_date(fmt, t)
    end
    display.auto_night = "sun"
    local from, to = NightMode.window()
    os.date = real_date
    display.auto_night = "off"
    Assert.is_true(from > 16 * 60 and from < 20 * 60, "日落开 " .. from)
    Assert.is_true(to > 4 * 60 and to < 8 * 60, "日出关 " .. to)
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
    display.auto_light_periods = { 3, 8, 15, 20, 18, 12, 7, 3 }
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

do -- 时段查找：边界归新时段，末段剩余算到零点
    local i, remain = NightMode.period(0)
    Assert.eq(i, 1)
    Assert.eq(remain, 5 * 60)
    i, remain = NightMode.period(5 * 60 - 1)
    Assert.eq(i, 1)
    Assert.eq(remain, 1)
    i = NightMode.period(5 * 60)
    Assert.eq(i, 2, "起点属于新时段")
    i = NightMode.period(12 * 60)
    Assert.eq(i, 4, "中午")
    i, remain = NightMode.period(DAY - 1)
    Assert.eq(i, 8, "深夜")
    Assert.eq(remain, 1)
end

-- 无传感器分支读 os.date("*t")，其他格式照常。
local real_date, fake_now = os.date, nil
os.date = function(fmt, t)
    if fmt == "*t" and t == nil and fake_now then return fake_now end
    return real_date(fmt, t)
end

do -- 无传感器（Kobo 等没有 hasLightSensor 方法）：按时段查表，与夜间模式无关
    lights = {}
    Device.hasLightSensor = nil
    Assert.is_false(NightMode.hasSensor())
    Assert.eq(NightMode.lightSource(), "clock")
    fake_now = { hour = 12, min = 30, sec = 10 }
    NightMode.applyLight()
    Assert.len(lights, 1)
    Assert.eq(lights[1], 0.2, "中午 20%")
    Assert.eq(scheduled[NightMode.sense], 30 * 60 - 10, "排到下一时段起点")
    NightMode.onResume()
    Assert.len(lights, 1, "同一时段不重设（保留手动调节）")
    fake_now = { hour = 13, min = 0, sec = 0 }
    NightMode.sense()
    Assert.eq(lights[2], 0.18, "进入下午")
    fake_now = { hour = 23, min = 59, sec = 59 }
    NightMode.sense()
    Assert.eq(lights[3], 0.03, "深夜")
    Assert.eq(scheduled[NightMode.sense], 1, "至少 1 秒")
    display.auto_light_periods[8] = 5
    NightMode.applyLight()
    Assert.eq(lights[4], 0.05, "改了设置立刻按当前时段重设")
    local switches = #events
    display.auto_night_from, display.auto_night_to = 0, DAY
    NightMode.setMode("schedule")
    Assert.len(events, switches + 1)
    Assert.len(lights, 4, "昼夜切换不碰亮度")
    NightMode.setMode("off")
    Assert.len(lights, 4)
    display.auto_light = false
    NightMode.applyLight()
    Assert.len(lights, 4, "关闭后不设亮度")
    Assert.is_nil(scheduled[NightMode.sense], "关闭后不排程")
end

do -- 开关自动亮度：落盘并立即生效，不依赖自动夜间模式
    lights, saved = {}, 0
    fake_now = { hour = 6, min = 0, sec = 0 }
    NightMode.setLight(true)
    Assert.is_true(display.auto_light)
    Assert.eq(saved, 1)
    Assert.eq(display.auto_night, "off")
    Assert.eq(lights[1], 0.08, "清晨 8%")
    NightMode.setLight(false)
    Assert.is_false(display.auto_light)
    Assert.len(lights, 1, "关闭不设亮度")
end

do -- 手动调亮度关闭自动亮度；自动设亮度、亮度没变（改色温）、关灯（休眠）都不算
    fake_now = { hour = 12, min = 0, sec = 0 }
    NightMode.setLight(true)
    Assert.is_true(display.auto_light, "自己设亮度触发的广播不算手动")
    NightMode.onFrontlightChanged()
    Assert.is_true(display.auto_light, "亮度没变不算")
    powerd.on = false
    NightMode.onFrontlightChanged()
    Assert.is_true(display.auto_light, "关灯不算")
    powerd.on, powerd.percent = true, 50
    NightMode.onFrontlightChanged()
    Assert.is_false(display.auto_light, "手动调了就关闭")
    Assert.is_nil(scheduled[NightMode.sense], "关闭后不排程")
    saved = 0
    NightMode.onFrontlightChanged()
    Assert.eq(saved, 0, "已关闭不再重复关")
end

do -- 自动设 0% 关了灯，用户手动开灯也算手动调节
    display.auto_light_periods[4] = 0
    NightMode.setLight(true)
    Assert.is_true(display.auto_light)
    Assert.is_false(powerd.on)
    powerd.on, powerd.percent = true, 21
    NightMode.onFrontlightChanged()
    Assert.is_false(display.auto_light)
    display.auto_light_periods[4] = 20
end

do -- 天气：白天时段乘倍率，每小时重看；夜间不看天气；离线取不到回落到 1
    lights = {}
    display.auto_light_periods = { 3, 8, 15, 20, 18, 12, 7, 3 }
    weather_reply = { code = "rain" }
    fake_now = { hour = 12, min = 0, sec = 0 }
    NightMode.setLight(true)
    Assert.eq(lights[#lights], 0.32, "中午 20% × 雨天 1.6")
    Assert.is_true(display.auto_light, "天气重设亮度不算手动")
    Assert.eq(scheduled[NightMode.sense], 3600, "白天每小时重看天气")
    local count = #lights
    NightMode.sense()
    Assert.len(lights, count, "天气没变不重设")
    weather_reply = { code = "overcast" }
    NightMode.sense()
    Assert.eq(lights[#lights], 0.3, "转阴 20% × 1.5")
    display.auto_light_periods[4] = 80
    NightMode.applyLight()
    Assert.eq(lights[#lights], 1, "封顶 100%")
    display.auto_light_periods[4] = 20
    weather_fetches = 0
    fake_now = { hour = 23, min = 0, sec = 0 }
    NightMode.sense()
    Assert.eq(lights[#lights], 0.03, "深夜不乘倍率")
    Assert.eq(weather_fetches, 0, "夜间不取天气")
    Assert.eq(scheduled[NightMode.sense], 3600, "深夜到零点")
    weather_reply = {}
    fake_now = { hour = 9, min = 0, sec = 0 }
    NightMode.sense()
    Assert.eq(lights[#lights], 0.15, "离线取不到天气按原值")
    NightMode.setLight(false)
end

os.date = real_date

do -- 没有前光：不做任何亮度动作
    display.auto_light = true
    Device.hasFrontlight = function() return false end
    Assert.is_nil(NightMode.lightSource())
end
