--[[--
zlib 镜像竞速与动态镜像列表缓存：
- 本地长期缓存 cfg.mirrors，有可用镜像时不访问 MIRRORS_API
- 首次并发竞速最多 5 个镜像，失败时滑动窗口补位；第一个成功的胜出并取消其余
- 本地列表所有镜像都不可用（全挂或全在 dead_bases）时，自动从 MIRRORS_API 拉取新列表并持久化
- serial 请求依次尝试，最多 3 个

@module tests.store.zlib.client_race_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local pending, cancelled = {}, {}
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        ok = function(code) return code >= 200 and code < 300 end,
        header = function(res, name) return res.headers and res.headers[name:lower()] end,
        request = function(opts, cb)
            local entry = { url = opts.url, cb = cb }
            pending[#pending + 1] = entry
            return { cancel = function() cancelled[opts.url] = true end }
        end,
    }
end
package.loaded["http.cache"] = nil
package.preload["http.cache"] = function()
    return { key = function() return "k" end, fetch = function(_key, _ttl, load, cb) return load(cb) or { cancel = function() end } end }
end

local saved = 0
package.loaded["utils.settings"] = { saveSource = function() saved = saved + 1 end }

local function freshClient(cfg)
    pending, cancelled = {}, {}
    package.loaded["store.zlib.client"] = nil
    local Client = require("store.zlib.client")
    return Client.new(cfg), Client
end

local CACHED = {
    "https://m1.example",
    "https://m2.example",
    "https://m3.example",
    "https://m4.example",
}

-- 1. 并发竞速：5 个同时发出（base_url + 4 个本地缓存），第 3 个先答成功，其余取消，不访问 MIRRORS_API
local client, Client = freshClient({ base_url = "https://a.example", mirrors = CACHED })
---@type integer, table|nil
local calls, data = 0, nil
client:_jsonAsync("GET", "/eapi/x", {}, function(d) calls = calls + 1; data = d end)
Assert.eq(#pending, 5)
for _idx = 1, 5 do
    Assert.is_true(pending[_idx].url ~= Client.MIRRORS_API, "本地缓存有可用镜像时不应请求镜像目录")
end
pending[1].cb({ code = 503 })
Assert.eq(calls, 0)
pending[3].cb({ code = 200, body = '{"success":1}' })
Assert.eq(calls, 1)
Assert.eq(data.success, 1)
Assert.is_true(cancelled[pending[2].url] and cancelled[pending[4].url] and cancelled[pending[5].url])
pending[5].cb({ code = 200, body = '{"success":1}' })
Assert.eq(calls, 1, "胜出后迟到的回包不再回调")

-- 同场失败的镜像被落盘拉黑，胜出的不拉黑
Assert.eq(saved, 1)
Assert.is_true(client.cfg.dead_bases[pending[1].url:match("^https://[^/]+")] ~= nil)
Assert.is_nil(client.cfg.dead_bases[pending[3].url:match("^https://[^/]+")])

-- 2. 已有胜出镜像：后续请求不再竞速，只发给它
pending = {}
client:_jsonAsync("GET", "/eapi/y", {}, function() end)
Assert.eq(#pending, 1)
Assert.eq(pending[1].url, "https://a.example/eapi/y")

-- 3. 首次无本地缓存：先请求 MIRRORS_API，写回 cfg.mirrors 长期缓存，再用下发列表发请求
do
    saved = 0
    local cfg = {}
    local c, Cls = freshClient(cfg)
    local got, err
    c:_jsonAsync("GET", "/eapi/x", {}, function(d, e) got, err = d, e end)
    Assert.eq(#pending, 1)
    Assert.eq(pending[1].url, Cls.MIRRORS_API)
    pending[1].cb({
        code = 200,
        body = '{"code":200,"data":{"mirrors":["https://s1.example/","https://s2.example"]}}',
    })
    Assert.eq(saved, 1, "拉取到的镜像列表应持久化")
    Assert.len(cfg.mirrors, 2)
    Assert.eq(cfg.mirrors[1], "https://s1.example")
    Assert.eq(#pending, 3)
    pending[2].cb({ code = 200, body = '{"success":1}' })
    Assert.is_nil(err)
    Assert.eq(got.success, 1)
end

-- 4. 本地缓存所有镜像都在本轮失败：自动向 MIRRORS_API 刷新，跳过已试过的镜像，用新镜像成功
do
    saved = 0
    local cfg = { mirrors = { "https://old1.example", "https://old2.example" } }
    local c, Cls = freshClient(cfg)
    local got, err
    c:_jsonAsync("GET", "/eapi/x", {}, function(d, e) got, err = d, e end)
    Assert.eq(#pending, 2)
    pending[1].cb({ code = 503 })
    pending[2].cb({ code = 503 })
    -- 本地所有镜像都不可用，触发服务器拉取
    Assert.eq(#pending, 3)
    Assert.eq(pending[3].url, Cls.MIRRORS_API)
    pending[3].cb({
        code = 200,
        body = '{"code":200,"data":{"mirrors":["https://old1.example","https://new1.example"]}}',
    })
    Assert.eq(saved, 1)
    Assert.eq(cfg.mirrors[2], "https://new1.example")
    -- old1 本轮已失败过，只发给 new1
    Assert.eq(#pending, 4)
    Assert.eq(pending[4].url, "https://new1.example/eapi/x")
    pending[4].cb({ code = 200, body = '{"success":1}' })
    Assert.is_nil(err)
    Assert.eq(got.success, 1)
end

-- 5. 本地缓存所有镜像早已在 dead_bases 里：直接向 MIRRORS_API 拉新并清空 dead_bases
do
    local now = os.time()
    local cfg = {
        mirrors = { "https://d1.example", "https://d2.example" },
        dead_bases = { ["https://d1.example"] = now, ["https://d2.example"] = now },
    }
    local c, Cls = freshClient(cfg)
    local got
    c:_jsonAsync("GET", "/eapi/z", {}, function(d) got = d end)
    Assert.eq(#pending, 1)
    Assert.eq(pending[1].url, Cls.MIRRORS_API)
    pending[1].cb({ code = 200, body = '{"code":200,"data":{"mirrors":["https://fresh.example"]}}' })
    Assert.is_nil(cfg.dead_bases)
    Assert.eq(#pending, 2)
    Assert.eq(pending[2].url, "https://fresh.example/eapi/z")
    pending[2].cb({ code = 200, body = '{"success":1}' })
    Assert.eq(got.success, 1)
end

-- 6. 拉黑的镜像在仍有其他可用缓存镜像时跳过，且不访问 MIRRORS_API
do
    local cfg = {
        mirrors = { "https://a.example", "https://b.example", "https://c.example" },
        dead_bases = { ["https://a.example"] = os.time() },
    }
    local c, Cls = freshClient(cfg)
    c:_jsonAsync("GET", "/eapi/z", {}, function() end)
    Assert.eq(#pending, 2)
    for _idx = 1, #pending do
        Assert.is_true(pending[_idx].url:find("a.example", 1, true) == nil)
        Assert.is_true(pending[_idx].url ~= Cls.MIRRORS_API)
    end
end

-- 7. 取消发生在刷新 MIRRORS_API 期间：中断刷新请求且不回调
do
    local c, Cls = freshClient({})
    local called = 0
    local job = c:_jsonAsync("GET", "/eapi/x", {}, function() called = called + 1 end)
    Assert.eq(pending[1].url, Cls.MIRRORS_API)
    job.cancel()
    Assert.is_true(cancelled[Cls.MIRRORS_API])
    pending[1].cb({ code = 200, body = '{"code":200,"data":{"mirrors":["https://s1.example"]}}' })
    Assert.eq(called, 0)
    Assert.eq(#pending, 1)
end

-- 8. MIRRORS_API 失败且本地缓存尚在：保留旧缓存不清空，只清 dead_bases 兜底重试一次
do
    local now = os.time()
    local cfg = {
        mirrors = { "https://keep.example" },
        dead_bases = { ["https://keep.example"] = now },
    }
    local c, Cls = freshClient(cfg)
    local got
    c:_jsonAsync("GET", "/eapi/x", {}, function(d) got = d end)
    Assert.eq(pending[1].url, Cls.MIRRORS_API)
    pending[1].cb({ code = 502 })
    Assert.eq(cfg.mirrors[1], "https://keep.example", "服务器失败不能清空已有缓存列表")
    Assert.eq(pending[2].url, "https://keep.example/eapi/x")
    pending[2].cb({ code = 200, body = '{"success":1}' })
    Assert.eq(got.success, 1)
end

-- 9. serial：本地有足够可用镜像时一次只发一个，最多 3 个，不触发服务器刷新
do
    local c = freshClient({ mirrors = CACHED })
    calls = 0
    local err
    c:_jsonAsync("GET", "/eapi/x", { serial = true }, function(_d, e) calls = calls + 1; err = e end)
    Assert.eq(#pending, 1)
    pending[1].cb({ code = 503 })
    Assert.eq(#pending, 2)
    pending[2].cb({ code = 503 })
    pending[3].cb({ code = 503 })
    Assert.eq(#pending, 3)
    Assert.eq(calls, 1)
    Assert.matches(err, "503")
end

-- 10. 重启后直接复用落盘的 last_mirror（不重新 5 路竞速），失效再展开竞速；同时清理过期的 dead_bases
do
    local cfg = {
        mirrors = CACHED,
        last_mirror = "https://m3.example",
        dead_bases = { ["https://ancient.example"] = 1 },
    }
    -- 模拟进程重启（freshClient 重载模块，内存 pinned_base 为空）
    local c = freshClient(cfg)
    local got
    c:_jsonAsync("GET", "/eapi/x", {}, function(d) got = d end)
    Assert.eq(#pending, 1, "重启后命中落盘 last_mirror 时只发 1 路，不并发竞速")
    Assert.eq(pending[1].url, "https://m3.example/eapi/x")
    pending[1].cb({ code = 200, body = '{"success":1}' })
    Assert.eq(got.success, 1)
    Assert.is_nil(cfg.dead_bases, "过期的 dead_bases 应在保存时顺手清理")

    -- 落盘的 last_mirror 失效时：清空钉住并自动拉宽并发竞速其余缓存镜像，新胜出源覆盖 last_mirror
    local c2 = freshClient(cfg)
    got = nil
    c2:_jsonAsync("GET", "/eapi/y", {}, function(d) got = d end)
    Assert.eq(#pending, 1)
    Assert.eq(pending[1].url, "https://m3.example/eapi/y")
    pending[1].cb({ code = 503 })
    -- m3 失效后应把其余缓存（m1, m2, m4）展开并发
    Assert.eq(#pending, 4)
    pending[2].cb({ code = 200, body = '{"success":1}' })
    Assert.eq(got.success, 1)
    Assert.eq(cfg.last_mirror, "https://m1.example")
    Assert.is_true(cfg.dead_bases["https://m3.example"] ~= nil)
end

return true
