--[[--
online.paper：城市取自首页天气设置，图按竖屏尺寸、水墨屏带 ink。
@module tests.online.paper_spec
--]]

local Assert = require("support.assert")

local color = false
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 1448 end,
            getHeight = function() return 1072 end,
            isColorEnabled = function() return color end,
        },
    }
end
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local home = { home_weather_city = " Beijing " }
package.preload["utils.settings"] = function()
    return { get = function() return home end }
end

local Paper = require("online.paper")

Assert.eq(Paper.image_ext, "png")
Assert.eq(Paper:url(), "https://api.ankio.net/paper?type=json&city=Beijing")
Assert.eq(Paper:imageUrl(), "https://api.ankio.net/paper?width=1072&height=1448&city=Beijing&ink=1")
color = true
Assert.eq(Paper:imageUrl(), "https://api.ankio.net/paper?width=1072&height=1448&city=Beijing")
home.home_weather_city = nil
Assert.eq(Paper:url(), "https://api.ankio.net/paper?type=json&city=")

-- fetch 的 args.city 只改这次请求的 URL，不读设置、不留在实例上。
local fetched
local Request = require("http.request")
local get = Request.get
Request.get = function(url, _opts, cb) fetched = url; cb(nil, "down") end
Paper:fetch({ city = "上海", ttl = 0 }, function() end)
Request.get = get
Assert.eq(fetched, "https://api.ankio.net/paper?type=json&city=%E4%B8%8A%E6%B5%B7")
Assert.is_nil(rawget(Paper, "city"))
Assert.eq(Paper:parse('{"code":200,"data":{"title":"今日要闻","date":"2026年10月20日"}}').title, "今日要闻")
Assert.is_nil(Paper:parse('{"code":500}'))

return true
