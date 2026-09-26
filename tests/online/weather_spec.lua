--[[--
online.weather：空 city= 走 IP；图标走 assets CDN；日预报收进 days。
@module tests.online.weather_spec
--]]

local Assert = require("support.assert")

package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { url = url, opts = opts, cb = cb }
            return { cancel = function() end }
        end,
    }
end

local Weather = require("online.weather")

do -- 有城市 + 默认 TTL + 丰富字段
    requests = {}
    local got
    Weather:fetch({ city = "Shanghai" }, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/weather?city=Shanghai")
    Assert.eq(requests[1].opts.cache_ttl, 3600)
    Assert.is_true(requests[1].opts.allow_redirects)
    requests[1].cb([[{
        "current_condition":[{"temp_C":"26","FeelsLikeC":"25","weatherCode":"122",
            "humidity":"76","winddir16Point":"NNE","windspeedKmph":"7",
            "pressure":"1019","visibility":"16","precipMM":"0.2","uvIndex":"5",
            "cloudcover":"100",
            "weatherDesc":[{"value":"Overcast "}],
            "lang_zh":[{"value":"阴"}]}],
        "nearest_area":[{"areaName":[{"value":"Pootung"}],"region":[{"value":"Shanghai"}],
            "latitude":"31.239","longitude":"121.504"}],
        "weather":[{
            "date":"2026-09-09","maxtempC":"30","mintempC":"22",
            "astronomy":[{"sunrise":"05:48 AM","sunset":"06:12 PM"}],
            "hourly":[{},{},{},{},{"weatherCode":"122","weatherDesc":[{"value":"Overcast"}],
                "lang_zh":[{"value":"阴"}]}]
        },{
            "date":"2026-09-10","maxtempC":"28","mintempC":"21",
            "hourly":[{"weatherCode":"176","weatherDesc":[{"value":"Rain"}]}]
        }]
    }]])
    Assert.eq(got.temp, "26")
    Assert.eq(got.feels, "25")
    Assert.eq(got.desc, "阴")
    Assert.eq(got.code, "122")
    Assert.eq(got.city, "Pootung")
    Assert.eq(got.humidity, "76")
    Assert.eq(got.wind, "东北")
    Assert.eq(got.wind_kmph, "7")
    Assert.eq(got.high, "30")
    Assert.eq(got.low, "22")
    Assert.eq(got.sunrise, "05:48 AM")
    Assert.eq(got.latitude, 31.239)
    Assert.eq(got.longitude, 121.504)
    Assert.eq(got.icon, "overcast")
    Assert.eq(got.image, "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/weather/yin.png")
    Assert.len(got.days, 2)
    Assert.eq(got.days[2].date, "2026-09-10")
    Assert.eq(got.days[2].icon, "rain")
end

do -- 空城市 + 测试不走缓存；无 lang_zh 时用码表
    requests = {}
    local got
    Weather:fetch({ city = "", ttl = 0 }, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/weather?city=")
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb([[{
        "current_condition":[{"temp_C":"18","weatherCode":"113",
            "weatherDesc":[{"value":"Sunny"}]}],
        "nearest_area":[{"areaName":[{"value":"San Jose"}]}]
    }]])
    Assert.eq(got.temp, "18")
    Assert.eq(got.city, "San Jose")
    Assert.eq(got.desc, "晴")
    Assert.eq(got.icon, "sunny")
    Assert.eq(got.image, Weather.iconUrl("sunny"))
end

do -- 关键词兜底
    Assert.eq(Weather.iconKey(nil, "大雾"), "fog")
    Assert.eq(Weather.iconKey(nil, "Haze"), "haze")
    Assert.eq(Weather.iconUrl("unknown"),
        "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/weather/unknow.png")
end

return true
