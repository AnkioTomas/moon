--[[--
online.myrl：摊平摸鱼日报 JSON，TTL 算到当天结束。
@module tests.online.myrl_spec
--]]

local Assert = require("support.assert")

local color = false
package.preload["device"] = function()
    return {
        screen = {
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

local Myrl = require("online.myrl")

do
    requests = {}
    local got
    Myrl:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/myrl?type=json")
    Assert.is_true(math.abs(requests[1].opts.cache_ttl - require("online.base").untilMidnight()) <= 1)
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

do -- 水墨屏带 ink；彩屏不带
    color = false
    Assert.eq(Myrl:imageUrl(720, 960), "https://api.ankio.net/myrl?width=720&height=960&ink=1")
    color = true
    Assert.eq(Myrl:imageUrl(720, 960), "https://api.ankio.net/myrl?width=720&height=960")
end

return true
