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
Assert.eq(Paper:parse('{"code":200,"data":{"title":"今日要闻","date":"2026年10月20日"}}').title, "今日要闻")
Assert.is_nil(Paper:parse('{"code":500}'))

return true
