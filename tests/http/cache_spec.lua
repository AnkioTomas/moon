--[[--
http.cache 键：METHOD + path + 规范化 query

@module tests.http_cache_spec
--]]

local Assert = require("support.assert")
local Cache = require("http.cache")

do
    Assert.eq(Cache.queryString(nil), "")
    Assert.eq(Cache.queryString({}), "")
end

-- 同参不同 pairs 顺序 → 同一 query string
do
    local a = Cache.queryString({ b = 2, a = 1, c = 3 })
    local b = Cache.queryString({ c = 3, a = 1, b = 2 })
    Assert.eq(a, "a=1&b=2&c=3")
    Assert.eq(a, b)
end

-- 键含查询；提供 query 表时剥掉 url 自带 ?
do
    Assert.eq(
        Cache.key("get", "https://x/index/book/list", { page = 2, search = "三体" }),
        "GET https://x/index/book/list?page=2&search=三体"
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

-- 不同查询 → 不同键
do
    local k1 = Cache.key("GET", "https://x/list", { page = 1 })
    local k2 = Cache.key("GET", "https://x/list", { page = 2 })
    Assert.is_true(k1 ~= k2)
end
