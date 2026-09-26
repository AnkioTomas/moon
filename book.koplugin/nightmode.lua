--[[--
自动夜间模式（定时或日出日落）与自动亮度。

只在昼夜交替那一刻切换，用户中途手动切的夜间模式不会被立刻改回。
日出日落离线计算（NOAA 简化算法，误差一两分钟）；经纬度在选模式时经天气接口按 IP / 天气地点取一次落盘。

自动亮度：有光线传感器（仅部分 Kindle）按环境光档位查表，档位变了才改；
否则在昼夜交替时设白天 / 夜间亮度。两条路都不覆盖用户在同一档位 / 同一昼夜里的手动调节。

@module koplugin.book.nightmode
--]]

local MoonSettings = require("utils.settings")
local Text = require("utils.text")

local NightMode = {}

local DAY = 24 * 60
local SENSOR_INTERVAL = 30
-- 上次应用的昼夜状态；nil 表示本进程还没应用过，下次 tick 必切。
local last
-- 上次应用的环境光档位；nil 表示下次 sense 必设。
local last_level

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
---@return "sensor"|"phase"|nil
function NightMode.lightSource()
    if not MoonSettings.get("display").auto_light then return nil end
    if not require("device"):hasFrontlight() then return nil end
    return NightMode.hasSensor() and "sensor" or "phase"
end

---@param percent number 0 = 关灯
local function setBrightness(percent)
    require("ui.panel.desktop").setLevel("brightness", percent / 100)
end

---@param night boolean
local function phaseLight(night)
    local conf = MoonSettings.get("display")
    setBrightness(night and conf.auto_light_night or conf.auto_light_day)
end

--- 读环境光档位，档位变了才设亮度，然后排下一次读取。
function NightMode.sense()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(NightMode.sense)
    if NightMode.lightSource() ~= "sensor" then
        last_level = nil
        return
    end
    local level = require("device"):ambientBrightnessLevel()
    if level ~= last_level then
        last_level = level
        setBrightness(MoonSettings.get("display").auto_light_levels[level + 1])
    end
    UIManager:scheduleIn(SENSOR_INTERVAL, NightMode.sense)
end

--- 亮度设置改了：立刻按当前档位 / 昼夜重设一次亮度，不碰夜间模式。
function NightMode.applyLight()
    last_level = nil
    NightMode.sense()
    if last ~= nil and NightMode.lightSource() == "phase" then phaseLight(last) end
end

--- 开关自动亮度并立即生效。
---@param on boolean
function NightMode.setLight(on)
    local conf = MoonSettings.get("display")
    conf.auto_light = on
    MoonSettings.saveSection("display", conf)
    NightMode.applyLight()
end

--- 自动亮度开着却不会生效：没有传感器，又没开自动夜间模式提供昼夜时间。
---@return boolean
function NightMode.lightIdle()
    return NightMode.lightSource() == "phase" and MoonSettings.get("display").auto_night == "off"
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
        if NightMode.lightSource() == "phase" then phaseLight(night) end
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

--- 唤醒：睡眠期间跨过切换点就补切，环境光换了档就调亮度，都没变不动。
function NightMode.onResume()
    NightMode.tick()
    NightMode.sense()
end

return NightMode
