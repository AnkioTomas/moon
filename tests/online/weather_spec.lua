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
Assert.eq(Weather.ttl, 4 * 3600)

do -- 有城市 + 默认 TTL + 丰富字段
    requests = {}
    local got
    Weather:fetch({ city = "Shanghai" }, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/weather?city=Shanghai")
    Assert.is_nil(Weather.city, "试查不写回 city")
    Assert.eq(requests[1].opts.cache_ttl, 0)
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
    Assert.eq(got.image, require("http.mirror").url("assets/weather/yin.png"))
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

do -- 逐 3 小时档：解析成绝对时间；upcoming 从 now 往后取，跨天接上；没有逐小时退回明天起的逐日
    local wx = Weather:parse([[{
        "current_condition":[{"temp_C":"20","weatherCode":"113"}],
        "weather":[{
            "date":"2026-10-13","maxtempC":"23","mintempC":"16",
            "hourly":[{"time":"0","tempC":"17","weatherCode":"113"},
                {"time":"1800","tempC":"21","weatherCode":"176"},
                {"time":"2100","tempC":"19","weatherCode":"122"}]
        },{
            "date":"2026-10-14","maxtempC":"25","mintempC":"18",
            "hourly":[{"time":"0","tempC":"18","weatherCode":"143"},{"time":"300","tempC":"17"}]
        }]
    }]])
    Assert.len(wx.hours, 5)
    Assert.eq(wx.hours[2].at, "2026-10-13 18:00")
    Assert.eq(wx.hours[2].icon, "rain")
    Assert.eq(wx.hours[4].at, "2026-10-14 00:00")

    local now = os.time{ year = 2026, month = 10, day = 13, hour = 17, min = 30 }
    local next3 = Weather.upcoming(wx, 3, now)
    Assert.len(next3, 3)
    Assert.eq(next3[1].kind, "hour")
    Assert.eq(next3[1].label, "18:00")
    Assert.eq(next3[1].temp, "21")
    Assert.eq(next3[1].image, Weather.iconUrl("rain"))
    Assert.eq(next3[3].label, "00:00", "跨天接上第二天")
    Assert.len(Weather.upcoming(wx, 10, now), 4, "只有未来档")

    local late = os.time{ year = 2026, month = 10, day = 14, hour = 4 }
    local days = Weather.upcoming(wx, 4, late)
    Assert.len(days, 0, "逐小时全过期、也没有明天之后的日预报")

    wx.hours = nil
    days = Weather.upcoming(wx, 4, now)
    Assert.len(days, 1, "旧缓存没有逐小时：退回明天起的逐日")
    Assert.eq(days[1].kind, "day")
    Assert.eq(days[1].label, "2026-10-14")
    Assert.eq(days[1].low, "18")
    Assert.eq(days[1].high, "25")
    Assert.len(Weather.upcoming(nil, 4, now), 0)
end

do -- 无 current_condition 不是天气
    Assert.is_nil(Weather:parse('{"nearest_area":[]}'))
end

do -- 关键词兜底
    Assert.eq(Weather.iconKey(nil, "大雾"), "fog")
    Assert.eq(Weather.iconKey(nil, "Haze"), "haze")
    Assert.matches(Weather.iconUrl("unknown"), "assets/weather/unknow%.png$")
end

return true
