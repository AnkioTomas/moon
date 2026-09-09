--[[--
天气。空 city= 走 IP；不带参数会被接口默认成上海。
图标不进插件包，走仓库 assets/weather，和字典一样经 jsDelivr 拉。

@module koplugin.book.online.weather
--]]

local Online = require("online.base")
local Text = require("utils.text")

local ICON_URL = "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/weather/"
local ICONS = {
    sunny = "sunny.png",
    cloud = "dyun.png",
    overcast = "yin.png",
    fog = "wu.png",
    haze = "mai.png",
    rain = "rain.png",
    snow = "snow.png",
    wind = "sha.png",
    unknown = "unknow.png",
}

-- WWO weatherCode → 图标键。对不上再扫描述关键词。
local CODE = {
    ["113"] = "sunny",
    ["116"] = "cloud", ["119"] = "cloud",
    ["122"] = "overcast",
    ["143"] = "fog", ["248"] = "fog", ["260"] = "fog",
    ["176"] = "rain", ["200"] = "rain", ["263"] = "rain", ["266"] = "rain",
    ["281"] = "rain", ["284"] = "rain", ["293"] = "rain", ["296"] = "rain",
    ["299"] = "rain", ["302"] = "rain", ["305"] = "rain", ["308"] = "rain",
    ["311"] = "rain", ["314"] = "rain", ["353"] = "rain", ["356"] = "rain",
    ["359"] = "rain", ["386"] = "rain", ["389"] = "rain",
    ["179"] = "snow", ["182"] = "snow", ["185"] = "snow", ["227"] = "snow",
    ["230"] = "snow", ["317"] = "snow", ["320"] = "snow", ["323"] = "snow",
    ["326"] = "snow", ["329"] = "snow", ["332"] = "snow", ["335"] = "snow",
    ["338"] = "snow", ["350"] = "snow", ["362"] = "snow", ["365"] = "snow",
    ["368"] = "snow", ["371"] = "snow", ["374"] = "snow", ["377"] = "snow",
    ["392"] = "snow", ["395"] = "snow",
}

local ZH = {
    ["113"] = "晴", ["116"] = "少云", ["119"] = "多云", ["122"] = "阴",
    ["143"] = "薄雾", ["176"] = "阵雨", ["179"] = "阵雪", ["182"] = "雨夹雪",
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

local KEYWORDS = {
    { "sunny", { "晴", "sunny", "clear" } },
    { "rain", { "雨", "rain", "drizzle", "shower" } },
    { "snow", { "雪", "snow", "sleet" } },
    { "haze", { "霾", "haze", "smog" } },
    { "fog", { "雾", "fog", "mist" } },
    { "overcast", { "阴", "overcast" } },
    { "cloud", { "云", "cloud" } },
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
---@field icon string
---@field image string
---@field days BookWeatherDay[]

---@class BookOnlineWeather : BookOnline
local Weather = setmetatable({
    ttl = 3600,
    allow_redirects = true,
}, Online)
Weather.__index = Weather

---@param node any
---@return string|nil
local function firstValue(node)
    if type(node) ~= "table" then return Online.nonempty(node) end
    local first = node[1]
    if type(first) == "table" then return Online.nonempty(first.value) end
    return Online.nonempty(first)
end

---@param value any
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
    return ICON_URL .. (ICONS[key] or ICONS.unknown)
end

---@param code string|nil
---@param zh any
---@param en any
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

---@param args table|nil
---@return string
function Weather:url(args)
    local city = Text.trim(args and args.city or "")
    return self.host .. "/weather?city=" .. Text.urlEncode(city)
end

---@param body string|nil
---@return BookWeather|nil
function Weather:parse(body)
    local payload = Online.decode(body)
    if type(payload) ~= "table" then return nil end
    local current = payload.current_condition
    current = type(current) == "table" and current[1] or nil
    if type(current) ~= "table" then return nil end
    local code = numberish(current.weatherCode)
    local desc, icon, image = look(code, current.lang_zh, current.weatherDesc)
    local area = payload.nearest_area
    area = type(area) == "table" and area[1] or nil
    local days = {}
    for _, day in ipairs(type(payload.weather) == "table" and payload.weather or {}) do
        if type(day) == "table" then
            days[#days + 1] = dayRow(day)
        end
        if #days >= 3 then break end
    end
    local today = days[1] or {}
    local astro = type(payload.weather) == "table"
        and type(payload.weather[1]) == "table"
        and payload.weather[1].astronomy
    astro = type(astro) == "table" and astro[1] or nil
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
        icon = icon,
        image = image,
        days = days,
    }
end

return Weather
