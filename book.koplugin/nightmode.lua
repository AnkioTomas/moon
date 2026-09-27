--[[--
自动夜间模式（定时或日出日落）与自动亮度。

只在昼夜交替那一刻切换，用户中途手动切的夜间模式不会被立刻改回。
日出日落离线计算（NOAA 简化算法，误差一两分钟）；经纬度在选模式时经天气接口按 IP / 天气地点取一次落盘。

自动亮度：有光线传感器（仅部分 Kindle）按环境光档位查表，否则按一天中的时段查表，与夜间模式无关。
无传感器时白天时段再乘天气倍率估算环境光（阴雨天更暗，多补光）。
目标亮度变了才改；用户手动调亮度即关闭自动亮度。

@module koplugin.book.nightmode
--]]

local MoonSettings = require("utils.settings")
local Text = require("utils.text")

local NightMode = {}

local DAY = 24 * 60
local SENSOR_INTERVAL = 30
local WEATHER_INTERVAL = 3600
-- 无传感器时各时段的起始分钟：凌晨、清晨、上午、中午、下午、傍晚、晚上、深夜，与 auto_light_periods 一一对应。
NightMode.PERIOD_STARTS = { 0, 5 * 60, 8 * 60, 11 * 60, 13 * 60, 17 * 60, 19 * 60, 22 * 60 }
-- 有天光、天气会影响环境光的时段（清晨到傍晚）。
local DAYLIGHT = { false, true, true, true, true, true, false, false }
-- 按 Weather.iconKey 分类的补光倍率；没列出的（晴、大风、未知、离线取不到）为 1。
local WEATHER_GAIN = { cloud = 1.2, haze = 1.3, snow = 1.4, overcast = 1.5, fog = 1.5, rain = 1.6 }
-- 当前天气倍率。
local gain = 1
-- 上次应用的昼夜状态；nil 表示本进程还没应用过，下次 tick 必切。
local last
-- 上次设下的目标亮度百分比；nil 表示下次 sense 必设。
local last_percent
-- 自动亮度设下后读回的亮度百分比；nil 表示没在管亮度或正在设，此时的亮度变化不算手动调节。
local applied

---@param d number
---@return number
local function rad(d) return d * math.pi / 180 end

---@param r number
---@return number
local function deg(r) return r * 180 / math.pi end

--- 日出或日落的本地分钟数；极夜 / 极昼返回 nil 和 dark（true = 太阳不升起）。
---@param yday number 年内第几天
---@param lat number
---@param lon number
---@param tz number 本地时区偏移（分钟）
---@param rising boolean
---@return number|nil minute
---@return boolean|nil dark
local function sunEvent(yday, lat, lon, tz, rising)
    local lng_hour = lon / 15
    local t = yday + ((rising and 6 or 18) - lng_hour) / 24
    local m = 0.9856 * t - 3.289
    local l = (m + 1.916 * math.sin(rad(m)) + 0.020 * math.sin(rad(2 * m)) + 282.634) % 360
    local ra = deg(math.atan(0.91764 * math.tan(rad(l)))) % 360
    ra = (ra + math.floor(l / 90) * 90 - math.floor(ra / 90) * 90) / 15
    local sin_dec = 0.39782 * math.sin(rad(l))
    local cos_dec = math.cos(math.asin(sin_dec))
    local cos_h = (math.cos(rad(90.833)) - sin_dec * math.sin(rad(lat))) / (cos_dec * math.cos(rad(lat)))
    if cos_h > 1 or cos_h < -1 then return nil, cos_h > 1 end
    local h = deg(math.acos(cos_h))
    if rising then h = 360 - h end
    local ut = (h / 15 + ra - 0.06571 * t - 6.622 - lng_hour) % 24
    return math.floor(ut * 60 + tz + 0.5) % DAY
end

--- 按日出日落算夜间窗口 [日落, 日出)。极夜整天是夜，极昼没有夜。
---@param yday number
---@param lat number
---@param lon number
---@param tz number
---@return number from
---@return number to
function NightMode.sunWindow(yday, lat, lon, tz)
    local rise, rise_dark = sunEvent(yday, lat, lon, tz, true)
    local set, set_dark = sunEvent(yday, lat, lon, tz, false)
    if rise and set then return set, rise end
    if rise_dark or set_dark then return 0, DAY end
    return 0, 0
end

--- minute 是否落在夜间窗口 [from, to)；可跨零点，from == to 表示没有夜晚。
---@param minute number
---@param from number
---@param to number
---@return boolean
function NightMode.isNight(minute, from, to)
    if from <= to then return minute >= from and minute < to end
    return minute >= from or minute < to
end

--- 距下一个切换点（from / to / 零点重算）的秒数，至少 1 秒。
---@param minute number
---@param sec number
---@param from number
---@param to number
---@return number
function NightMode.nextDelay(minute, sec, from, to)
    local wait = DAY
    for _, mark in ipairs({ from, to, DAY }) do
        local d = (mark - minute) % DAY
        if d == 0 then d = DAY end
        if d < wait then wait = d end
    end
    return math.max(1, wait * 60 - sec)
end

---@param now number
---@return number
local function tzMinutes(now)
    local utc = os.date("!*t", now)
    utc.isdst = os.date("*t", now).isdst
    return os.difftime(now, os.time(utc)) / 60
end

--- 今天的夜间窗口；关闭时返回 nil。
---@param now number|nil
---@return number|nil from
---@return number|nil to
function NightMode.window(now)
    local conf = MoonSettings.get("display")
    if conf.auto_night == "schedule" then
        return conf.auto_night_from, conf.auto_night_to
    end
    if conf.auto_night == "sun" then
        now = now or os.time()
        return NightMode.sunWindow(os.date("*t", now).yday, conf.auto_night_lat, conf.auto_night_lon, tzMinutes(now))
    end
end

--- 设备有光线传感器。只有 Kindle 定义了 hasLightSensor，其他设备没有这个方法。
---@return boolean
function NightMode.hasSensor()
    local Device = require("device")
    return Device.hasLightSensor ~= nil and Device:hasLightSensor()
end

--- 自动亮度的来源；关闭或没有前光时返回 nil。
---@return "sensor"|"clock"|nil
function NightMode.lightSource()
    if not MoonSettings.get("display").auto_light then return nil end
    if not require("device"):hasFrontlight() then return nil end
    return NightMode.hasSensor() and "sensor" or "clock"
end

--- minute 所在时段序号（1 起）与距下一时段起点的分钟数。
---@param minute number
---@return number index
---@return number remain
function NightMode.period(minute)
    local starts = NightMode.PERIOD_STARTS
    local i = #starts
    while starts[i] > minute do i = i - 1 end
    return i, (starts[i + 1] or DAY) - minute
end

--- 按时段（白天再乘天气倍率）算目标亮度与下次检查的秒数；白天至少每小时重看一次天气。
---@param percents number[]
---@return number percent
---@return number delay
---@return boolean daylight
local function clockTarget(percents)
    local t = os.date("*t")
    local i, remain = NightMode.period(t.hour * 60 + t.min)
    local delay = remain * 60 - t.sec
    if not DAYLIGHT[i] then return percents[i], math.max(1, delay), false end
    return math.min(100, math.floor(percents[i] * gain + 0.5)), math.max(1, math.min(delay, WEATHER_INTERVAL)), true
end

--- 读环境光档位或按时段估算，目标亮度变了才设，然后排下一次读取（传感器轮询，时段等到下一个起点）。
function NightMode.sense()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(NightMode.sense)
    local source = NightMode.lightSource()
    if not source then
        last_percent, applied = nil, nil
        return
    end
    local conf = MoonSettings.get("display")
    local percent, delay, daylight
    if source == "sensor" then
        percent, delay = conf.auto_light_levels[require("device"):ambientBrightnessLevel() + 1], SENSOR_INTERVAL
    else
        percent, delay, daylight = clockTarget(conf.auto_light_periods)
    end
    if percent ~= last_percent then
        local Panel = require("ui.panel.desktop")
        last_percent, applied = percent, nil
        Panel.setLevel("brightness", percent / 100)
        applied = Panel.lightPercent("brightness")
    end
    UIManager:scheduleIn(delay, NightMode.sense)
    if daylight then NightMode.refreshWeather() end
end

--- 取当前天气（http 缓存 1 小时；离线且缓存过期时拿到空表，倍率回落到 1），倍率变了就重算亮度。
function NightMode.refreshWeather()
    local Weather = require("online.weather")
    Weather:fetch({ city = Text.trim(MoonSettings.get("home").home_weather_city) }, function(wx)
        local g = WEATHER_GAIN[Weather.iconKey(wx.code, wx.desc)] or 1
        if g == gain then return end
        gain = g
        NightMode.sense()
    end)
end

--- 前光变化（FrontlightStateChanged，同步广播）：灯亮着且亮度不是自动设的值，就是用户手动调了，关掉自动亮度。
--- 关灯不算：休眠和自动设 0% 都会关灯；改色温不动亮度。
function NightMode.onFrontlightChanged()
    if not applied or require("device"):getPowerDevice():isFrontlightOff() then return end
    if require("ui.panel.desktop").lightPercent("brightness") == applied then return end
    NightMode.setLight(false)
end

--- 亮度设置改了：立刻按当前档位 / 时段重设一次亮度，不碰夜间模式。
function NightMode.applyLight()
    last_percent = nil
    NightMode.sense()
end

--- 开关自动亮度并立即生效。
---@param on boolean
function NightMode.setLight(on)
    local conf = MoonSettings.get("display")
    conf.auto_light = on
    MoonSettings.saveSection("display", conf)
    NightMode.applyLight()
end

--- 按当前时刻判定昼夜，状态变了才切，然后排到下一个切换点。
function NightMode.tick()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(NightMode.tick)
    local now = os.time()
    local from, to = NightMode.window(now)
    if not from then
        last = nil
        return
    end
    local t = os.date("*t", now)
    local minute = t.hour * 60 + t.min
    local night = NightMode.isNight(minute, from, to)
    if night ~= last then
        last = night
        UIManager:broadcastEvent(require("ui/event"):new("SetNightMode", night))
    end
    UIManager:scheduleIn(NightMode.nextDelay(minute, t.sec, from, to), NightMode.tick)
end

--- 切换模式并立即按新规则应用一次。
---@param mode "off"|"schedule"|"sun"
function NightMode.setMode(mode)
    local conf = MoonSettings.get("display")
    conf.auto_night = mode
    MoonSettings.saveSection("display", conf)
    last = nil
    NightMode.tick()
end

--- 经天气接口取经纬度并落盘。天气地点留空时按 IP。
---@param cb fun(ok: boolean, city: string|nil)
---@return { cancel: fun() }
function NightMode.locate(cb)
    local city = Text.trim(MoonSettings.get("home").home_weather_city)
    return require("online.weather"):fetch({ city = city }, function(wx)
        if not wx.latitude or not wx.longitude then return cb(false) end
        local conf = MoonSettings.get("display")
        conf.auto_night_lat, conf.auto_night_lon = wx.latitude, wx.longitude
        MoonSettings.saveSection("display", conf)
        cb(true, wx.city)
    end)
end

-- ── 生命周期（main.lua 一行转发）───────────────────────

--- 插件 onCreate：FM / Reader 两个实例都会调，tick 幂等。
function NightMode.onCreate()
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(NightMode.tick)
    UIManager:nextTick(NightMode.sense)
end

function NightMode.onPause()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(NightMode.tick)
    UIManager:unschedule(NightMode.sense)
end

--- 唤醒：睡眠期间跨过切换点就补切，环境光换档 / 跨时段就调亮度，都没变不动。
function NightMode.onResume()
    NightMode.tick()
    NightMode.sense()
end

return NightMode
