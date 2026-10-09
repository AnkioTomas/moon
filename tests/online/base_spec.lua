--[[--
online.base：HTTP 不走 cache；过期才入队；解析失败读 load。
@module tests.online.base_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function()
    return require("support.json_stub")
end

local cache_dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-online-base-spec"
os.execute("mkdir -p '" .. cache_dir .. "'")
package.preload["utils.paths"] = function()
    return {
        onlineCacheDir = function() return cache_dir end,
        ensureOnlineCache = function() end,
    }
end

local connected = true
package.loaded["ui/network/manager"] = nil
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local requests = {}
local cancelled = 0
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { url = url, opts = opts, cb = cb }
            return { cancel = function() cancelled = cancelled + 1 end }
        end,
    }
end

local by_key, last_result = {}, nil
package.preload["workers.tasks"] = function()
    return {
        get = function(key) return by_key[key] end,
        enqueue = function(spec)
            by_key[spec.key] = spec
            spec.state = "running"
            spec.cancel = function()
                if spec.handle then spec.handle.cancel() end
                by_key[spec.key] = nil
            end
            spec.handle = spec.run(function() end, function(result)
                last_result = result
                by_key[spec.key] = nil
            end)
            return spec
        end,
    }
end

local Online = require("online.base")
local Child = setmetatable({ name = "child", title = "试", ttl = 60 }, Online)
Child.__index = Child
function Child:url()
    return self.host .. "/x?q=" .. tostring(self.q or "")
end
function Child:parse(body)
    local data = Online.decode(body)
    if not data or not data.ok then return nil end
    return data
end
local stored
function Child:store(data)
    stored = data
    self.data = data
    self._expire = os.time() + 60
    self._cache_key = self:url()
end
function Child:load() return { ok = "disk" } end

do -- HTTP 不走 cache；成功走 store
    requests, stored = {}, nil
    local got
    Child.q = "a"
    Child:fetch(nil, function(data) got = data end)
    Assert.eq(requests[1].url, "https://api.ankio.net/x?q=a")
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb('{"ok":"net"}')
    Assert.eq(got.ok, "net")
    Assert.eq(stored.ok, "net")
end

do -- args.ttl 覆盖；解析失败且缓存过期则空
    requests, stored = {}, nil
    Child.data, Child._expire, Child._cache_key = nil, nil, nil
    local got, err
    Child:fetch({ ttl = 0 }, function(data, e) got, err = data, e end)
    Assert.eq(requests[1].opts.cache_ttl, 0)
    requests[1].cb(nil, "down")
    Assert.is_nil(got)
    Assert.eq(err, "down")
    Assert.is_nil(stored)
end

do -- 200 但解析失败：带 parse，不合成空表；ensure 失败以便重试
    requests, stored, last_result, by_key = {}, nil, nil, {}
    Child.data, Child._expire, Child._cache_key, Child._watchers = nil, nil, nil, nil
    local got, err, notified
    Child:fetch({}, function(data, e) got, err = data, e end)
    requests[1].cb('{"x":1}')
    Assert.is_nil(got)
    Assert.eq(err, "parse")
    Assert.is_nil(stored)

    requests = {}
    Child:watch(function(data, e) notified = { data = data, err = e } end)
    Child:ensure()
    requests[1].cb('{"x":1}')
    Assert.is_false(last_result.ok)
    Assert.eq(last_result.err, "parse")
    Assert.eq(notified.err, "parse")
    Assert.is_nil(notified.data)
    Assert.is_nil(Child:current())
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

do -- ensure 入队一次；多个 watch 一起收
    requests, stored, cancelled, by_key = {}, nil, 0, {}
    Child.data, Child._expire, Child._cache_key, Child._watchers = nil, nil, nil, nil
    local a, b
    Child:watch(function(data) a = data end)
    Child:watch(function(data) b = data end)
    Child:ensure()
    Assert.eq(#requests, 1)
    Assert.is_nil(Child:current(), "过期或没有时 current 是空")
    Child:fetch({ ttl = 0 }, function() end)
    Assert.eq(#requests, 2, "试查另走 fetch")
    requests[1].cb('{"ok":"net"}')
    Assert.eq(a.ok, "net")
    Assert.eq(b.ok, "net")
    Assert.eq(Child:current().ok, "net")
    Assert.eq(stored.ok, "net")
end

do -- unwatch 只摘等待
    requests, stored, cancelled, by_key = {}, nil, 0, {}
    Child.data, Child._expire, Child._cache_key, Child._watchers = nil, nil, nil, nil
    local seen
    local cb = function() seen = true end
    Child:watch(cb)
    Child:ensure()
    Child:unwatch(cb)
    requests[1].cb('{"ok":"kept"}')
    Assert.is_nil(seen)
    Assert.eq(Child:current().ok, "kept")
end

do -- 参数变了才拆掉重拉
    requests, cancelled, by_key = {}, 0, {}
    Child.data, Child._expire, Child._cache_key, Child._watchers = nil, nil, nil, nil
    Child.q = "a"
    Child:ensure()
    Assert.eq(requests[1].url, "https://api.ankio.net/x?q=a")
    Child.q = "b"
    Child:ensure()
    Assert.eq(#requests, 2)
    Assert.eq(cancelled, 1)
    Assert.eq(requests[2].url, "https://api.ankio.net/x?q=b")
end

do -- 未过期不入队
    local File = setmetatable({ name = "child", title = "试", ttl = 60 }, Online)
    File.__index = File
    function File:url()
        return self.host .. "/f"
    end
    function File:parse(body)
        return Online.decode(body)
    end
    File:store({ ok = "file" })
    File.data, File._expire = nil, nil
    Assert.is_true(File:fresh())
    requests, by_key = {}, {}
    File:ensure()
    Assert.eq(#requests, 0)
    Assert.eq(File:current().ok, "file")
    File._expire = os.time() - 1
    Assert.is_nil(File:current(), "过期是空")

    function File:url()
        return self.host .. "/f?c=" .. tostring(self.city or "")
    end
    File.city = "a"
    File:store({ ok = "a" })
    Assert.is_true(File:fresh())
    File.city = "b"
    Assert.is_false(File:fresh())
    requests, by_key = {}, {}
    File:ensure()
    Assert.eq(#requests, 1)
    Assert.eq(requests[1].url, "https://api.ankio.net/f?c=b")
end

do -- 离线不拉网，联网再入队
    requests, stored, by_key = {}, nil, {}
    Child.data, Child._expire, Child._watchers = nil, nil, nil
    Child.q = nil
    connected = false
    local got
    Child:watch(function(data) got = data end)
    Child:ensure()
    Assert.eq(#requests, 0)
    Assert.is_nil(got)
    connected = true
    Child:ensure()
    Assert.eq(#requests, 1)
    requests[1].cb('{"ok":"late"}')
    Assert.eq(got.ok, "late")
end

os.execute("rm -rf '" .. cache_dir .. "'")
return true
