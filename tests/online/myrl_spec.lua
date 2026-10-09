--[[--
online.myrl：摊平摸鱼日报 JSON，TTL 算到当天结束。
@module tests.online.myrl_spec
--]]

local Assert = require("support.assert")

local color = false
local screen_w, screen_h = 720, 960
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return screen_w end,
            getHeight = function() return screen_h end,
            isColorEnabled = function() return color end,
        },
    }
end
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

local Online = require("online.base")
local Myrl = require("online.myrl")
Assert.eq(Myrl.ttl, Online.untilMidnight)

do
    requests = {}
    local got
    Myrl:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/myrl?type=json")
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb([[{
        "code":200,
        "data":{
            "date":{"lunar":"农历七月廿八"},
            "holiday":{"label":"距中秋节还有16天"},
            "history":[{"year":"1991","title":"苏联解体"},{"year":"1976","title":"毛泽东逝世"}],
            "news":["冷空气","上海生娃"],
            "quote":{"hitokoto":"月亮","from":"博尔赫斯"}
        }
    }]])
    Assert.eq(got.lunar, "农历七月廿八")
    Assert.eq(got.holiday, "距中秋节还有16天")
    Assert.eq(got.quote_text, "月亮")
    Assert.eq(got.quote_from, "博尔赫斯")
    Assert.len(got.history, 2)
    Assert.len(got.news, 2)
end

do -- 空对象 / 错误外壳不是日报，不能缓存到午夜
    Assert.is_nil(Myrl:parse('{"code":200,"data":{}}'))
    Assert.is_nil(Myrl:parse('{"code":500}'))
end

do -- 水墨屏带 ink；彩屏不带；横屏对调成竖屏
    color = false
    Assert.eq(Myrl.image_ext, "png")
    Assert.eq(Myrl:imageUrl(), "https://api.ankio.net/myrl?width=720&height=960&ink=1")
    color = true
    Assert.eq(Myrl:imageUrl(), "https://api.ankio.net/myrl?width=720&height=960")
    screen_w, screen_h = 960, 720
    Assert.eq(Myrl:imageUrl(), "https://api.ankio.net/myrl?width=720&height=960")
end

return true
