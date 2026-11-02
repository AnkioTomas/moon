--[[--
天气。空 city= 走 IP；不带参数会被接口默认成上海。
图标不进插件包，走仓库 assets/weather，和字典一样经 jsDelivr 拉。

@module koplugin.book.online.weather
--]]

local Online = require("online.base")
local Text = require("utils.text")

-- 彩色透明 PNG。sha.png / unknow.png 是已发布的 URL，不改名。
local ICONS = {
    sunny = "sunny.png",
    cloud = "dyun.png",
    cloudy = "cloudy.png",
    overcast = "yin.png",
    mist = "mist.png",
    fog = "wu.png",
    haze = "mai.png",
    drizzle = "drizzle.png",
    rain = "rain.png",
    heavy_rain = "heavy_rain.png",
    freezing = "freezing.png",
    sleet = "sleet.png",
    snow = "snow.png",
    heavy_snow = "heavy_snow.png",
    blizzard = "blizzard.png",
    ice = "ice.png",
    thunder = "thunder.png",
    storm = "storm.png",
    thunder_snow = "thunder_snow.png",
    wind = "sha.png",
    dust = "dust.png",
    unknown = "unknow.png",
}

-- WWO weatherCode → 图标键。对不上再扫描述关键词。
local CODE = {
    ["113"] = "sunny",
    ["116"] = "cloud",
    ["119"] = "cloudy",
    ["122"] = "overcast",
    ["125"] = "haze",
    ["128"] = "dust", ["131"] = "dust", ["134"] = "dust",
    ["137"] = "dust", ["140"] = "dust",
    ["143"] = "mist",
    ["146"] = "haze", ["149"] = "haze", ["152"] = "haze", ["155"] = "haze",
    ["158"] = "dust", ["161"] = "dust",
    ["176"] = "rain",
    ["179"] = "snow",
    ["182"] = "sleet",
    ["185"] = "freezing",
    ["200"] = "thunder",
    ["227"] = "blizzard",
    ["230"] = "blizzard",
    ["248"] = "fog",
    ["260"] = "fog",
    ["263"] = "drizzle",
    ["266"] = "drizzle",
    ["281"] = "freezing",
    ["284"] = "freezing",
    ["293"] = "rain",
    ["296"] = "rain",
    ["299"] = "rain",
    ["302"] = "rain",
    ["305"] = "heavy_rain",
    ["308"] = "heavy_rain",
    ["311"] = "freezing",
    ["314"] = "freezing",
    ["317"] = "sleet",
    ["320"] = "sleet",
    ["323"] = "snow",
    ["326"] = "snow",
    ["329"] = "snow",
    ["332"] = "snow",
    ["335"] = "heavy_snow",
    ["338"] = "heavy_snow",
    ["350"] = "ice",
    ["353"] = "rain",
    ["356"] = "heavy_rain",
    ["359"] = "heavy_rain",
    ["362"] = "sleet",
    ["365"] = "sleet",
    ["368"] = "snow",
    ["371"] = "heavy_snow",
    ["374"] = "ice",
    ["377"] = "ice",
    ["386"] = "storm",
    ["389"] = "storm",
    ["392"] = "thunder_snow",
    ["395"] = "thunder_snow",
}

local ZH = {
    ["113"] = "晴", ["116"] = "少云", ["119"] = "多云", ["122"] = "阴",
    ["125"] = "霾", ["128"] = "尘霾", ["131"] = "扬尘", ["134"] = "沙尘暴",
    ["137"] = "沙暴", ["140"] = "强沙暴", ["143"] = "薄雾", ["146"] = "烟",
    ["149"] = "烟霾", ["152"] = "烟雾", ["155"] = "严重烟雾", ["158"] = "撒哈拉沙尘",
    ["161"] = "浮尘", ["176"] = "阵雨", ["179"] = "阵雪", ["182"] = "雨夹雪",
    ["200"] = "雷阵雨", ["227"] = "吹雪", ["230"] = "暴风雪", ["248"] = "雾",
    ["263"] = "小毛毛雨", ["266"] = "毛毛雨", ["293"] = "小雨", ["296"] = "小雨",
    ["299"] = "阵雨", ["302"] = "中雨", ["305"] = "大雨", ["308"] = "暴雨",
    ["311"] = "冻雨", ["323"] = "小雪", ["326"] = "小雪", ["332"] = "中雪",
    ["338"] = "大雪", ["353"] = "小阵雨", ["356"] = "强阵雨", ["359"] = "暴雨",
    ["386"] = "雷阵雨", ["389"] = "雷雨",
}

local WIND = {
    N = "北", S = "南", E = "东", W = "西",
    NE = "东北", NW = "西北", SE = "东南", SW = "西南",
    NNE = "东北", ENE = "东北", NNW = "西北", WNW = "西北",
    SSE = "东南", ESE = "东南", SSW = "西南", WSW = "西南",
}

-- 长词在前。雨夹雪含「雨」，薄雾含「雾」，晴间多云含「多云」。
local KEYWORDS = {
    { "thunder_snow", { "雷雪", "雷阵雪", "thundersnow", "snow with thunder" } },
    { "storm", { "雷雨", "雷阵雨", "雷暴", "thunderstorm" } },
    { "thunder", { "雷", "thunder" } },
    { "blizzard", { "暴风雪", "吹雪", "blizzard" } },
    { "sleet", { "雨夹雪", "sleet" } },
    { "freezing", { "冻雨", "freezing rain", "freezing drizzle" } },
    { "ice", { "冰雹", "冰粒", "hail", "ice pellet" } },
    { "heavy_rain", { "暴雨", "大雨", "torrential", "heavy rain" } },
    { "heavy_snow", { "大雪", "heavy snow" } },
    { "drizzle", { "毛毛雨", "drizzle" } },
    { "dust", { "沙尘", "扬沙", "浮尘", "dust", "sand" } },
    { "haze", { "霾", "haze", "smog", "smoke", "烟雾" } },
    { "mist", { "薄雾", "mist" } },
    { "fog", { "雾", "fog" } },
    { "snow", { "雪", "snow" } },
    { "rain", { "雨", "rain", "shower" } },
    { "overcast", { "阴", "overcast" } },
    { "cloud", { "晴间", "少云", "局部多云", "partly" } },
    { "cloudy", { "多云", "cloudy" } },
    { "cloud", { "云", "cloud" } },
    { "sunny", { "晴", "sunny", "clear" } },
    { "wind", { "风", "wind", "gale" } },
}

---@class BookWeatherDay
---@field date string|nil
---@field high string|nil
---@field low string|nil
---@field desc string|nil
---@field code string|nil
---@field icon string
---@field image string

---@class BookWeatherHour
---@field at string 观测地本地时间 "YYYY-MM-DD HH:MM"，按字符串比较先后
---@field temp string|nil
---@field desc string|nil
---@field code string|nil
---@field icon string
---@field image string

---@class BookWeatherForecast
---@field kind "hour"|"day"
---@field label string hour 为 "HH:MM"，day 为 "YYYY-MM-DD"
---@field temp string|nil hour 的温度
---@field low string|nil day 的最低温
---@field high string|nil day 的最高温
---@field image string

---@class BookWeather
---@field temp string|nil
---@field feels string|nil
---@field desc string|nil
---@field city string|nil
---@field code string|nil
---@field humidity string|nil
---@field wind string|nil
---@field wind_kmph string|nil
---@field pressure string|nil
---@field visibility string|nil
---@field precip string|nil
---@field uv string|nil
---@field cloud string|nil
---@field high string|nil
---@field low string|nil
---@field sunrise string|nil
---@field sunset string|nil
---@field latitude number|nil
---@field longitude number|nil
---@field icon string
---@field image string
---@field days BookWeatherDay[]
---@field hours BookWeatherHour[]|nil 逐 3 小时预报，按时间升序；旧缓存没有

---@class BookOnlineWeather : BookOnline
---@field city string|nil 由首页 / 夜间模式写入，这里不读设置
local Weather = setmetatable({
    name = "weather",
    title = "天气",
    ttl = 4 * 3600,
}, Online)
Weather.__index = Weather

---@return string|nil
local function firstValue(node)
    if type(node) ~= "table" then return Online.nonempty(node) end
    local first = node[1]
    if type(first) == "table" then return Online.nonempty(first.value) end
    return Online.nonempty(first)
end

---@return string|nil
local function numberish(value)
    if type(value) == "number" then return tostring(value) end
    return Online.nonempty(value)
end

--- 图标键。先认 WWO 码，再扫中英描述。
---@param code string|nil
---@param desc string|nil
---@return string
function Weather.iconKey(code, desc)
    local key = CODE[tostring(code or "")]
    if key then return key end
    local lower = string.lower(desc or "")
    for i = 1, #KEYWORDS do
        local row = KEYWORDS[i]
        for j = 1, #row[2] do
            if lower:find(row[2][j], 1, true) then return row[1] end
        end
    end
    return "unknown"
end

---@param key string|nil
---@return string
function Weather.iconUrl(key)
    return require("http.mirror").url("assets/weather/" .. (ICONS[key] or ICONS.unknown))
end

---@param code string|nil
---@return string|nil
---@return string
---@return string
local function look(code, zh, en)
    local desc = firstValue(zh) or ZH[tostring(code or "")] or firstValue(en)
    local key = Weather.iconKey(code, desc)
    return desc, key, Weather.iconUrl(key)
end

---@param dir string|nil
---@return string|nil
local function windDir(dir)
    dir = Online.nonempty(dir)
    if not dir then return nil end
    return WIND[dir] or dir
end

---@param day table
---@return BookWeatherDay
local function dayRow(day)
    local hourly = type(day.hourly) == "table" and day.hourly or {}
    local noon = hourly[5] or hourly[1] or {}
    local code = numberish(noon.weatherCode)
    local desc, icon, image = look(code, noon.lang_zh, noon.weatherDesc)
    return {
        date = Online.nonempty(day.date),
        high = numberish(day.maxtempC),
        low = numberish(day.mintempC),
        desc = desc,
        code = code,
        icon = icon,
        image = image,
    }
end

--- 一天的逐小时档位追加到 out；time 是 "0" / "300" / … / "2100"（HHMM 去掉前导零）。
---@param day table
---@param out BookWeatherHour[]
local function hourRows(day, out)
    local date = Online.nonempty(day.date)
    if not date or type(day.hourly) ~= "table" then return end
    for _idx, hour in ipairs(day.hourly) do
        local hhmm = type(hour) == "table" and tonumber(hour.time)
        if hhmm then
            local code = numberish(hour.weatherCode)
            local desc, icon, image = look(code, hour.lang_zh, hour.weatherDesc)
            out[#out + 1] = {
                at = string.format("%s %02d:%02d", date, math.floor(hhmm / 100), hhmm % 100),
                temp = numberish(hour.tempC),
                desc = desc,
                code = code,
                icon = icon,
                image = image,
            }
        end
    end
end

--- 从 now 往后的 n 档预报：有逐小时取逐小时，没有取明天起的逐日，都没有返回空表。
--- 档位按 now 现算，不进缓存：同一份 4 小时缓存里过去的档位会自然滚掉。
---@param wx BookWeather|nil
---@param n integer
---@param now number|nil 时间戳，缺省当前
---@return BookWeatherForecast[]
function Weather.upcoming(wx, n, now)
    local out = {}
    if not wx then return out end
    local stamp = os.date("%Y-%m-%d %H:%M", now) --[[@as string]]
    for _idx, hour in ipairs(wx.hours or {}) do
        if #out >= n then return out end
        if hour.at > stamp then
            out[#out + 1] = { kind = "hour", label = hour.at:sub(12), temp = hour.temp, image = hour.image }
        end
    end
    if #out > 0 then return out end
    local today = stamp:sub(1, 10)
    for _idx, day in ipairs(wx.days or {}) do
        if #out >= n then break end
        if day.date and day.date > today then
            out[#out + 1] = { kind = "day", label = day.date, low = day.low, high = day.high, image = day.image }
        end
    end
    return out
end

---@return string
function Weather:url()
    local city = Text.trim(self.city or "")
    return self.host .. "/weather?city=" .. Text.urlEncode(city)
end

---@param body string|nil
---@return BookWeather|nil
function Weather:parse(body)
    local payload = Online.decode(body)
    if not payload then return nil end
    local current = payload.current_condition
    current = type(current) == "table" and current[1] or nil
    if type(current) ~= "table" then return nil end
    local code = numberish(current.weatherCode)
    local desc, icon, image = look(code, current.lang_zh, current.weatherDesc)
    local area = payload.nearest_area
    area = type(area) == "table" and area[1] or nil
    local weather = type(payload.weather) == "table" and payload.weather or {}
    local days, hours = {}, {}
    for _idx, day in ipairs(weather) do
        if type(day) == "table" then
            days[#days + 1] = dayRow(day)
            hourRows(day, hours)
        end
        if #days >= 3 then break end
    end
    local today = days[1] or {}
    local day1 = weather[1]
    local astro = type(day1) == "table" and type(day1.astronomy) == "table" and day1.astronomy[1] or nil
    return {
        temp = numberish(current.temp_C),
        feels = numberish(current.FeelsLikeC),
        desc = desc,
        city = type(area) == "table"
            and (firstValue(area.areaName) or firstValue(area.region))
            or nil,
        code = code,
        humidity = numberish(current.humidity),
        wind = windDir(current.winddir16Point),
        wind_kmph = numberish(current.windspeedKmph),
        pressure = numberish(current.pressure),
        visibility = numberish(current.visibility),
        precip = numberish(current.precipMM),
        uv = numberish(current.uvIndex),
        cloud = numberish(current.cloudcover),
        high = today.high,
        low = today.low,
        sunrise = astro and Online.nonempty(astro.sunrise) or nil,
        sunset = astro and Online.nonempty(astro.sunset) or nil,
        latitude = type(area) == "table" and tonumber(area.latitude) or nil,
        longitude = type(area) == "table" and tonumber(area.longitude) or nil,
        icon = icon,
        image = image,
        days = days,
        hours = hours,
    }
end

return Weather
