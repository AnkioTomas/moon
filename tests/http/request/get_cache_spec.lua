--[[--
Request.get 的 cache_ttl：命中 http.cache 不触网，成功才写入，带账号时按用户隔离。

@module tests.http.request_cache_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local rows = {}
local requested = 0
package.preload["db.http"] = function()
    return {
        get = function(key) return rows[key] and rows[key].value end,
        set = function(key, value, expires)
            rows[key] = { value = value, expires = expires }
            return true
        end,
        delete = function(key) rows[key] = nil end,
        clear = function() rows = {} return true end,
    }
end
package.preload["json"] = function()
    return { encode = function(v) return v end, decode = function(v) return v end }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
package.preload["http.request.header"] = function()
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
local status = 200
function Request.request(_, cb)
    requested = requested + 1
    cb({ code = status, body = "fresh" })
    return { cancel = function() end }
end

---@return string|nil body
---@return any err
local function get(url, opts)
    local body, err
    Request.get(url, opts, function(value, e) body, err = value, e end)
    Stubs.flush()
    return body, err
end

do -- 命中缓存：不发请求
    rows["GET https://x/a"] = { value = "cached" }
    requested = 0
    local body = get("https://x/a", { cache_ttl = 60 })
    Assert.eq(body, "cached")
    Assert.eq(requested, 0)
end

do -- 未命中：发请求并写入
    requested = 0
    local before = os.time()
    local body = get("https://x/b", { cache_ttl = 3600 })
    Assert.eq(body, "fresh")
    Assert.eq(requested, 1)
    Assert.eq(rows["GET https://x/b"].value, "fresh")
    Assert.is_true(rows["GET https://x/b"].expires >= before + 3600)
end

do -- 不设 ttl：不走缓存
    rows["GET https://x/c"] = { value = "should-not-see" }
    requested = 0
    local body = get("https://x/c", {})
    Assert.eq(body, "fresh")
    Assert.eq(requested, 1)
end

do -- 失败不写入
    status = 500
    local body, err = get("https://x/d", { cache_ttl = 60 })
    status = 200
    Assert.is_nil(body)
    Assert.eq(err, "HTTP 500")
    Assert.is_nil(rows["GET https://x/d"])
end

do -- 带账号：键按 auth_username 隔离，换账号不串缓存
    rows = {}
    get("https://nas/opds", { cache_ttl = 60, auth_username = "alice" })
    requested = 0
    local body = get("https://nas/opds", { cache_ttl = 60, auth_username = "bob" })
    Assert.eq(body, "fresh")
    Assert.eq(requested, 1, "另一个账号必须重新请求")
    Assert.is_nil(rows["GET https://nas/opds"], "带账号时不得写无隔离的键")
end

return true
