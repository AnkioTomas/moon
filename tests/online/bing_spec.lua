--[[--
online.bing：壁纸图走默认 302。
@module tests.online.bing_spec
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

local Bing = require("online.bing")

do
    Assert.eq(Bing:imageUrl(), "https://api.ankio.net/bing")
end

do -- JSON 元数据，TTL 算到午夜
    requests = {}
    local got
    Bing:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/bing?type=json")
    Assert.is_true(requests[1].opts.allow_redirects)
    Assert.is_true(math.abs(requests[1].opts.cache_ttl - require("online.base").untilMidnight()) <= 1)
    requests[1].cb([[{
        "code":200,
        "data":{
            "link":"https://www.bing.com/th?id=OHR.x.jpg",
            "title":"樱花",
            "copyright":"© Bing"
        }
    }]])
    Assert.eq(got.title, "樱花")
    Assert.eq(got.copyright, "© Bing")
    Assert.eq(got.link, "https://www.bing.com/th?id=OHR.x.jpg")
end

return true
