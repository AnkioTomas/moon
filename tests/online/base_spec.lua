--[[--
online.base：TTL 交给 Request.get；解析失败读 load。
@module tests.online.base_spec
--]]

local Assert = require("support.assert")

local color
package.preload["device"] = function()
    return {
        screen = {
            isColorEnabled = function() return color end,
        },
    }
end
package.preload["l10n"] = function() return { apply = function() end } end
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
local Child = setmetatable({ ttl = 60 }, Online)
Child.__index = Child
function Child:url(args)
    return self.host .. "/x?q=" .. tostring(args and args.q or "")
end
function Child:parse(body)
    local data = Online.decode(body)
    if not data or not data.ok then return nil end
    return data
end
local stored
function Child:store(data) stored = data end
function Child:load() return { ok = "disk" } end

do -- 默认 ttl；函数 ttl 请求时再算
    requests, stored = {}, nil
    local got
    Child:fetch({ q = "a" }, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/x?q=a")
    Assert.eq(requests[1].opts.cache_ttl, 60)
    requests[1].cb('{"ok":"net"}')
    Assert.eq(got.ok, "net")
    Assert.eq(stored.ok, "net")
    requests, stored = {}, nil
    Child.ttl = Online.untilMidnight
    Child:fetch({ q = "a" }, function() end)
    Assert.is_true(math.abs(requests[1].opts.cache_ttl - Online.untilMidnight()) <= 1)
    Child.ttl = 60
end

do -- args.ttl 覆盖；解析失败回落 load
    requests, stored = {}, nil
    local got, err
    Child:fetch({ ttl = 0 }, function(data, e) got, err = data, e end)
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb(nil, "down")
    Assert.eq(got.ok, "disk")
    Assert.eq(err, "down")
    Assert.is_nil(stored)
end

do -- 日更 TTL 是距午夜的剩余秒，不是滚动 24h
    local left = Online.untilMidnight()
    Assert.is_true(left >= 1)
    Assert.is_true(left <= 25 * 3600)
    local now = os.time()
    local t = os.date("*t", now)
    t.hour, t.min, t.sec = 0, 0, 0
    t.day = t.day + 1
    Assert.is_true(math.abs(left - (os.time(t) - now)) <= 1)
end

do -- 彩屏不要 ink
    color = true
    Assert.is_false(Online.useInk())
    color = false
    Assert.is_true(Online.useInk())
end

return true
