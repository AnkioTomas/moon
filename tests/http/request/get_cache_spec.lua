--[[--
Request.get 的 cache_ttl：命中 http.cache 不触网，成功才写入，带账号时按用户隔离。

@module tests.http.request_cache_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local rows = {}
local requested = 0
-- http 表的内存替身：http.cache 只用到按 key 读、upsert、按 key 删。
package.preload["utils.db"] = function()
    return {
        schema = function() end,
        rowexec = function(sql, key, now)
            local row = rows[key]
            if not row then return nil end
            if sql:find("expires >", 1, true) and row.expires and row.expires <= (now or 0) then
                return nil
            end
            return row.value
        end,
        exec = function(sql, key, value, expires)
            if sql:find("INSERT INTO http", 1, true) then
                rows[key] = { value = value, expires = expires }
            elseif sql:find("WHERE key=?", 1, true) then
                rows[key] = nil
            end
            return true
        end,
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

do -- 过期：当未命中，重新请求并写入
    rows["GET https://x/expired"] = { value = "old", expires = os.time() - 1 }
    requested = 0
    local before = os.time()
    local body = get("https://x/expired", { cache_ttl = 60 })
    Assert.eq(body, "fresh")
    Assert.eq(requested, 1)
    Assert.eq(rows["GET https://x/expired"].value, "fresh")
    Assert.is_true(rows["GET https://x/expired"].expires >= before + 60)
end

do -- 请求失败且 stale_on_error：回落过期缓存
    rows["GET https://x/stale"] = { value = "old", expires = os.time() - 1 }
    status = 500
    requested = 0
    local body, err = get("https://x/stale", { cache_ttl = 60, stale_on_error = true })
    status = 200
    Assert.eq(body, "old")
    Assert.is_nil(err)
    Assert.eq(requested, 1)
    Assert.eq(rows["GET https://x/stale"].value, "old", "失败回落不得覆盖旧值")
    Assert.is_true(rows["GET https://x/stale"].expires <= os.time())
end

do -- 失败且无旧缓存：透传错误
    status = 500
    local body, err = get("https://x/none", { cache_ttl = 60, stale_on_error = true })
    status = 200
    Assert.is_nil(body)
    Assert.eq(err, "HTTP 500")
    Assert.is_nil(rows["GET https://x/none"])
end

return true
