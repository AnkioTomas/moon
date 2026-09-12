--[[--
online.hitokoto：成功写设置；失败读设置。
@module tests.online.hitokoto_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local settings = {}
local saved = 0
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function() saved = saved + 1 end,
    }
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

local Hitokoto = require("online.hitokoto")

do -- 成功落盘
    settings, saved, requests = {}, 0, {}
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/hitokoto")
    Assert.eq(requests[1].opts.cache_ttl, 5 * 60)
    requests[1].cb('{"hitokoto":"月亮","from":"博尔赫斯","from_who":"作者"}')
    Assert.eq(got.text, "月亮")
    Assert.eq(got.source, "作者 · 博尔赫斯")
    Assert.eq(settings.lock_screen_quote_cache, "月亮")
    Assert.eq(settings.lock_screen_quote_source_cache, "作者 · 博尔赫斯")
    Assert.eq(saved, 1)
end

do -- 失败读本地
    settings = {
        lock_screen_quote_cache = "旧句",
        lock_screen_quote_source_cache = "旧出处",
    }
    saved, requests = 0, {}
    local got
    Hitokoto:fetch({}, function(data) got = data end)
    requests[1].cb(nil, "down")
    Assert.eq(got.text, "旧句")
    Assert.eq(got.source, "旧出处")
    Assert.eq(saved, 0)
end

do -- 无缓存：从一组回退里按天取一句
    settings = {}
    local a = Hitokoto:load()
    local b = Hitokoto.fallback()
    Assert.eq(a.text, b.text)
    Assert.eq(a.source, b.source)
    Assert.is_true(type(a.text) == "string" and a.text ~= "")
    Assert.eq(Hitokoto.fallback().text, a.text)
end

do -- 首页随机：缓存句拆成作者 / 作品
    settings = {
        lock_screen_quote_cache = "月亮",
        lock_screen_quote_source_cache = "作者 · 博尔赫斯",
    }
    local found
    for _ = 1, 80 do
        local quote = Hitokoto.random()
        if quote.text == "月亮" then
            found = quote
            break
        end
    end
    Assert.is_true(found ~= nil)
    Assert.eq(found.author, "作者")
    Assert.eq(found.title, "博尔赫斯")
end

return true
