--[[--
http.cache：键 = METHOD + path + 规范化 query；fetch 命中不 load、成功才写入。

@module tests.http_cache_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local rows = {}
package.preload["db.http"] = function()
    return {
        get = function(key) return rows[key] end,
        set = function(key, value)
            rows[key] = value
            return true
        end,
        delete = function(key) rows[key] = nil end,
    }
end
package.preload["json"] = function()
    return {
        encode = function(v) return v end,
        decode = function(v)
            if v == "corrupt" then error("bad json") end
            return v
        end,
    }
end

local Cache = require("http.cache")

-- 空 query 表等同于不带
do
    Assert.eq(Cache.key("GET", "https://x/a", {}), "GET https://x/a")
    Assert.eq(Cache.key(nil, "https://x/a"), "GET https://x/a")
end

-- 同参不同 pairs 顺序 → 同一键
do
    local a = Cache.key("GET", "https://x/l", { b = 2, a = 1, c = 3 })
    local b = Cache.key("GET", "https://x/l", { c = 3, a = 1, b = 2 })
    Assert.eq(a, "GET https://x/l?a=1&b=2&c=3")
    Assert.eq(a, b)
end

-- 键含查询；提供 query 表时剥掉 url 自带 ?
do
    Assert.eq(
        Cache.key("get", "https://x/index/book/list", { page = 2, search = "三体" }),
        "GET https://x/index/book/list?page=2&search=%E4%B8%89%E4%BD%93"
    )
    Assert.eq(
        Cache.key("GET", "https://x/index/book/list?junk=1", { page = 1 }),
        "GET https://x/index/book/list?page=1"
    )
    Assert.eq(
        Cache.key("GET", "https://x/index/book/filters"),
        "GET https://x/index/book/filters"
    )
end

-- 缓存键必须无歧义：单个值里的 &/= 不能与多个参数碰撞。
do
    local embedded = Cache.key("GET", "https://x/list", { a = "1&b=2" })
    local split = Cache.key("GET", "https://x/list", { a = 1, b = 2 })
    Assert.is_true(embedded ~= split)
    Assert.eq(embedded, "GET https://x/list?a=1%26b%3D2")
end

-- 不同查询 → 不同键
do
    local k1 = Cache.key("GET", "https://x/list", { page = 1 })
    local k2 = Cache.key("GET", "https://x/list", { page = 2 })
    Assert.is_true(k1 ~= k2)
end

-- POST 表单同样进入规范化参数，搜索关键词不能串缓存。
do
    local k1 = Cache.key("POST", "zlib://api/eapi/book/search", {
        message = "Lua",
        page = 1,
        limit = 200,
    })
    local k2 = Cache.key("POST", "zlib://api/eapi/book/search", {
        message = "Linux",
        page = 1,
        limit = 200,
    })
    Assert.eq(k1, "POST zlib://api/eapi/book/search?limit=200&message=Lua&page=1")
    Assert.is_true(k1 ~= k2)
end

-- scope 带长度前缀，不同用户不同键
do
    Assert.eq(Cache.key("GET", "https://x/a", nil, "alice"), "GET https://x/a @5:alice")
    Assert.is_true(Cache.key("GET", "https://x/a", nil, "a") ~= Cache.key("GET", "https://x/a", nil, "b"))
end

---@return integer loads, any value, any err
local function fetch(key, result, err)
    local loads, got, got_err = 0, nil, nil
    Cache.fetch(key, 60, function(done)
        loads = loads + 1
        done(result, err)
        return { cancel = function() end }
    end, function(value, e) got, got_err = value, e end)
    Stubs.flush()
    return loads, got, got_err
end

-- 命中：不 load
do
    rows.hit = "cached"
    local loads, value = fetch("hit", "fresh")
    Assert.eq(loads, 0)
    Assert.eq(value, "cached")
end

-- 未命中：load 一次并写入
do
    local loads, value = fetch("miss", "fresh")
    Assert.eq(loads, 1)
    Assert.eq(value, "fresh")
    Assert.eq(rows.miss, "fresh")
end

-- 失败：透传错误，不写入
do
    local loads, value, err = fetch("fail", nil, "boom")
    Assert.eq(loads, 1)
    Assert.is_nil(value)
    Assert.eq(err, "boom")
    Assert.is_nil(rows.fail)
end

-- JSON 损坏：删行当未命中
do
    rows.bad = "corrupt"
    local loads, value = fetch("bad", "fresh")
    Assert.eq(loads, 1)
    Assert.eq(value, "fresh")
    Assert.eq(rows.bad, "fresh")
end

-- 无 key：直接 load，同步回调，不碰缓存
do
    local called = false
    Cache.fetch(nil, 0, function(done)
        done("direct")
    end, function(value)
        called = value == "direct"
    end)
    Assert.is_true(called, "无 key 时同步透传")
end

-- 读缓存前取消：既不回调也不 load
do
    rows.cancel = "cached"
    local loads, called = 0, false
    local job = Cache.fetch("cancel", 60, function()
        loads = loads + 1
    end, function() called = true end)
    job.cancel()
    Stubs.flush()
    Assert.eq(loads, 0)
    Assert.is_false(called)
end
