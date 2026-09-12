--[[--
Request.get 的 cache_ttl：命中 http.cache 不触网，成功才写入。

@module tests.http.request_cache_spec
--]]

local Assert = require("support.assert")

local hits = {}
local stored
local requested = 0
package.preload["http.cache"] = function()
    return {
        key = function(method, url)
            return string.upper(method) .. " " .. url
        end,
        getAsync = function(key, cb)
            cb(hits[key])
            return { cancel = function() end }
        end,
        set = function(key, value, ttl)
            stored = { key = key, value = value, ttl = ttl }
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
package.preload["http.header"] = function()
    return { forRequest = function() return {} end }
end
package.preload["http.turbo"] = function()
    return {}
end
package.preload["utils.log"] = function()
    return { dbg = function() end, info = function() end, warn = function() end }
end
package.preload["utils.perf"] = function()
    return { now = function() return 0 end, elapsedMs = function() return 0 end }
end
package.preload["ffi/util"] = function()
    return { template = function(s, v) return (s:gsub("%%1", tostring(v))) end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end

local Request = require("http.request")
function Request.request(_, cb)
    requested = requested + 1
    cb({ code = 200, body = "fresh" })
    return { cancel = function() end }
end
function Request.ok(code)
    return tonumber(code) == 200
end

do -- 命中缓存：不发请求
    hits["GET https://x/a"] = "cached"
    requested, stored = 0, nil
    local body
    Request.get("https://x/a", { cache_ttl = 60 }, function(value)
        body = value
    end)
    Assert.eq(body, "cached")
    Assert.eq(requested, 0)
    Assert.is_nil(stored)
end

do -- 未命中：发请求并写入
    hits["GET https://x/b"] = nil
    requested, stored = 0, nil
    local body
    Request.get("https://x/b", { cache_ttl = 3600 }, function(value)
        body = value
    end)
    Assert.eq(body, "fresh")
    Assert.eq(requested, 1)
    Assert.eq(stored.key, "GET https://x/b")
    Assert.eq(stored.value, "fresh")
    Assert.eq(stored.ttl, 3600)
end

do -- 不设 ttl：不走缓存
    hits["GET https://x/c"] = "should-not-see"
    requested, stored = 0, nil
    local body
    Request.get("https://x/c", {}, function(value)
        body = value
    end)
    Assert.eq(body, "fresh")
    Assert.eq(requested, 1)
    Assert.is_nil(stored)
end

return true
