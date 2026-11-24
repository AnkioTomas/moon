--[[--
http.github：动态 GitHub 镜像目录缓存（api.ankio.net/gh/mirrors）、可用源持续复用、
全不可用再刷新、失败源落盘拉黑、HTML 拦截、断流换源与 Release 并发探测。

@module tests.http.github_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local saves = 0
local cfg = {
    mirror_last = "",
    mirror_files = {},
    mirror_release_last = "",
    mirror_release = {},
    mirror_dead = {},
}
package.preload["utils.settings"] = function()
    return {
        get = function(name) assert(name == "http"); return cfg end,
        save = function(name) assert(name == "http"); saves = saves + 1 end,
    }
end
package.loaded["utils.settings"] = nil

local calls, plan, cancelled_urls, probes = {}, {}, {}, {}
local function reset()
    calls, plan, cancelled_urls, probes = {}, {}, {}, {}
end

package.preload["http.request"] = function()
    local function reply(url, cb)
        calls[#calls + 1] = url
        local r = plan[url]
        if r == nil then r = "ok" end
        if r == "hang" then
            return { cancel = function() cancelled_urls[url] = true end }
        end
        require("ui/uimanager"):nextTick(function() cb(r) end)
        return { cancel = function() cancelled_urls[url] = true end }
    end
    return {
        get = function(url, _opts, cb)
            return reply(url, function(r)
                if type(r) == "table" then
                    cb(r.body, r.err, r.res or {})
                elseif r == "ok" then
                    cb("{}", nil, {})
                elseif r == "html" then
                    cb("<html>", nil, { headers = { ["Content-Type"] = "text/html" } })
                else
                    cb(nil, r)
                end
            end)
        end,
        download = function(opts, _dest, cb)
            if plan[opts.url] == "hang" then
                calls[#calls + 1] = opts.url
                return { cancel = function() cancelled_urls[opts.url] = true end }
            end
            return reply(opts.url, function(r)
                if r == "ok" then cb(true, nil, {}) else cb(false, r) end
            end)
        end,
        stream = function(opts, handlers)
            local p = { url = opts.url, handlers = handlers }
            p.cancel = function()
                if p.cancelled then return end
                p.cancelled = true
                handlers.on_done("cancelled")
            end
            probes[#probes + 1] = p
            return p
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["http.github"] = nil
local Github = require("http.github")

local M1 = "https://fastly.jsdelivr.net/gh/{owner}/{repo}@{ref}/{path}"
local M2 = "https://gh-proxy.org/https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}"
local M3 = "https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}"
local RAW_OFFICIAL = "https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}"

local function moonUrl(tpl, path)
    local vars = { owner = "AnkioTomas", repo = "moon", ref = "main", path = path }
    return (tpl:gsub("{(%w+)}", vars))
end

local function headers(length, mime)
    local map = { ["Content-Length"] = length and tostring(length), ["Content-Type"] = mime }
    return { get = function(_, k) return map[k] end }
end

-- ============================================================================
-- 仓库文件：url / get / download
-- ============================================================================

do -- 1. 默认无缓存时 url 回退内置 fastly
    Assert.eq(Github.url("assets/a.png"), moonUrl(Github.FALLBACK_FILES[1], "assets/a.png"))
    Assert.is_true(Github.url("assets/a.png"):find("fastly%.jsdelivr%.net") ~= nil)
end

do -- 2. 首次无缓存先请求 MIRRORS_API，落盘后后续一直复用可用镜像，不再请求目录接口
    saves = 0
    cfg.mirror_last, cfg.mirror_files, cfg.mirror_release, cfg.mirror_dead = "", {}, {}, {}
    reset()
    plan[Github.MIRRORS_API] = {
        body = '{"code":200,"data":{"jsdelivr":["https://fastly.jsdelivr.net/gh/{owner}/{repo}@{ref}/{path}"],"raw":["https://gh-proxy.org/https://raw.githubusercontent.com/"],"release":["https://gh-proxy.com/https://github.com/"]}}',
    }
    local body, err
    Github.get("assets/dict/manifest.json", nil, function(b, e) body, err = b, e end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.is_nil(err)
    Assert.eq(calls[1], Github.MIRRORS_API)
    Assert.eq(calls[2], moonUrl(M1, "assets/dict/manifest.json"))
    Assert.len(calls, 2)
    Assert.eq(cfg.mirror_last, M1)
    Assert.eq(cfg.mirror_files[1], M1)
    Assert.eq(cfg.mirror_files[2], M2)
    Assert.eq(cfg.mirror_files[3], RAW_OFFICIAL)
    Assert.eq(cfg.mirror_release[1], "https://gh-proxy.com/https://github.com")
    Assert.is_true(saves >= 1)

    -- 后续请求持续复用 M1，绝不触碰 MIRRORS_API
    reset()
    body = nil
    Github.get("assets/ime/manifest.json", nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.len(calls, 1)
    Assert.eq(calls[1], moonUrl(M1, "assets/ime/manifest.json"))
end

do -- 3. 失败 / HTML 假 200 换本地缓存下一个源，不查 MIRRORS_API；失败源落盘拉黑
    cfg.mirror_last = ""
    cfg.mirror_files = { M1, M2, M3 }
    cfg.mirror_dead = {}
    reset()
    local path = "assets/dict/manifest.json"
    plan[moonUrl(M1, path)] = "timeout"
    plan[moonUrl(M2, path)] = "html"
    local body
    Github.get(path, nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.len(calls, 3)
    Assert.eq(cfg.mirror_last, M3)
    Assert.eq(Github.url("assets/a.png"), moonUrl(M3, "assets/a.png"))
    Assert.is_true(Github.isDead(M1) and Github.isDead(M2))
    cfg.mirror_dead[M1] = os.time() - Github.DEAD_TTL - 1
    Assert.is_false(Github.isDead(M1))
end

do -- 4. 本地缓存全部失败：刷新 MIRRORS_API，跳过已试源，用新源成功
    cfg.mirror_last = ""
    cfg.mirror_files = { M1, M2 }
    cfg.mirror_dead = {}
    reset()
    local path = "assets/dict/manifest.json"
    plan[moonUrl(M1, path)] = "timeout"
    plan[moonUrl(M2, path)] = "timeout"
    plan[Github.MIRRORS_API] = {
        body = '{"code":200,"data":{"raw":["https://gh-proxy.org/https://raw.githubusercontent.com","https://edgeone.gh-proxy.org/https://raw.githubusercontent.com"]}}',
    }
    local body
    Github.get(path, nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.eq(calls[1], moonUrl(M1, path))
    Assert.eq(calls[2], moonUrl(M2, path))
    Assert.eq(calls[3], Github.MIRRORS_API)
    Assert.eq(calls[4], moonUrl(M3, path))
    Assert.eq(cfg.mirror_last, M3)
end

do -- 5. 本地缓存全在 mirror_dead：跳过死源（含死掉的 mirror_last），直接刷新 MIRRORS_API
    local now = os.time()
    cfg.mirror_last = M1
    cfg.mirror_files = { M1, M2 }
    cfg.mirror_dead = { [M1] = now, [M2] = now }
    reset()
    plan[Github.MIRRORS_API] = {
        body = '{"code":200,"data":{"raw":["https://edgeone.gh-proxy.org/https://raw.githubusercontent.com"]}}',
    }
    local body
    Github.get("assets/ok.json", nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.eq(calls[1], Github.MIRRORS_API)
    Assert.eq(calls[2], moonUrl(M3, "assets/ok.json"))
    Assert.is_nil(cfg.mirror_dead[M1])
end

do -- 6. MIRRORS_API 不可达：有旧死缓存则保留缓存、清黑名单兜底重试；无缓存则用 FALLBACK_FILES 且不落盘
    local now = os.time()
    cfg.mirror_last = ""
    cfg.mirror_files = { M1 }
    cfg.mirror_dead = { [M1] = now }
    reset()
    plan[Github.MIRRORS_API] = "down"
    local body
    Github.get("assets/keep.json", nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.eq(calls[1], Github.MIRRORS_API)
    Assert.eq(calls[2], moonUrl(M1, "assets/keep.json"))
    Assert.eq(cfg.mirror_files[1], M1)

    cfg.mirror_last, cfg.mirror_files, cfg.mirror_dead = "", {}, {}
    reset()
    plan[Github.MIRRORS_API] = "offline"
    body = nil
    Github.get("assets/fb.json", nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.eq(calls[1], Github.MIRRORS_API)
    Assert.eq(calls[2], moonUrl(Github.FALLBACK_FILES[1], "assets/fb.json"))
    Assert.len(cfg.mirror_files, 0)
end

do -- 7. 刷新 MIRRORS_API 期间取消：中断刷新请求且不回调
    cfg.mirror_last, cfg.mirror_files, cfg.mirror_dead = "", {}, {}
    reset()
    plan[Github.MIRRORS_API] = "hang"
    local called = false
    local h = Github.get("assets/cancel.json", nil, function() called = true end)
    Assert.eq(calls[1], Github.MIRRORS_API)
    h.cancel()
    Stubs.flush()
    Assert.is_true(cancelled_urls[Github.MIRRORS_API])
    Assert.is_false(called)
end

do -- 8. download：check 不过换源、断流超时换源、取消立刻清定时器、同步失败取消当前请求
    cfg.mirror_last, cfg.mirror_files, cfg.mirror_dead = "", { M1, M2 }, {}
    reset()
    plan[Github.MIRRORS_API] = "api down"
    local ok, err
    Github.download("assets/x", { check = function() return false, "size mismatch" end }, os.tmpname(), function(a, b) ok, err = a, b end)
    Stubs.flush()
    Assert.is_false(ok)
    Assert.eq(err, "size mismatch")
    Assert.len(calls, 3)

    reset()
    cfg.mirror_last, cfg.mirror_files, cfg.mirror_dead = "", { M1, M2 }, {}
    local path = "assets/hang.bin"
    local first = moonUrl(M1, path)
    plan[first] = "hang"
    ok = nil
    Github.download(path, {}, os.tmpname(), function(a) ok = a end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(calls[1], first)
    Assert.len(calls, 2)

    reset()
    cfg.mirror_last, cfg.mirror_files, cfg.mirror_dead = "", { M1 }, {}
    plan[first] = "hang"
    local unscheduled = 0
    local UIManager = require("ui/uimanager")
    local orig_unschedule = UIManager.unschedule
    UIManager.unschedule = function(self, fn) unscheduled = unscheduled + 1; return orig_unschedule(self, fn) end
    local done = false
    local h = Github.download(path, {}, os.tmpname(), function() done = true end)
    h.cancel()
    UIManager.unschedule = orig_unschedule
    Assert.is_true(cancelled_urls[first])
    Assert.is_true(unscheduled >= 1)
    Stubs.flush()
    Assert.is_false(done)

    -- 同步失败换源：cancel 取消的是第 2 个请求
    cfg.mirror_last, cfg.mirror_files, cfg.mirror_dead = "", { M1, M2 }, {}
    local cancelled, n = {}, 0
    local Req = require("http.request")
    local orig = Req.download
    Req.download = function(_opts, _dest, cb)
        n = n + 1
        local me = n
        if me == 1 then cb(false, "sync fail") end
        return { cancel = function() cancelled[#cancelled + 1] = me end }
    end
    local sh = Github.download("assets/sync.bin", {}, "/tmp/__gh_sync_spec", function() end)
    sh.cancel()
    Req.download = orig
    Assert.len(cancelled, 1)
    Assert.eq(cancelled[1], 2)
end

-- ============================================================================
-- Release 资产：pickRelease
-- ============================================================================

local REL = {
    url = "https://github.com/AnkioTomas/moon/releases/download/v1.0.0/book.koplugin-v1.0.0.zip",
    size = 4096,
}
local P1 = "https://p1.example/https://github.com"
local P2 = "https://p2.example/https://github.com"
local P3 = "https://p3.example/https://github.com"

do -- 9. Release 本地有缓存不查目录；胜出源被钉住，后续只测直连 + 它
    cfg.mirror_release_last, cfg.mirror_release, cfg.mirror_dead = "", { P1, P2, P3 }, {}
    reset()
    local picked
    Github.pickRelease(REL, function(u) picked = u end)
    Assert.len(calls, 0)
    Assert.len(probes, 4)
    probes[2].handlers.on_headers(502, headers())
    probes[3].handlers.on_headers(200, headers(4096, "application/octet-stream"))
    Stubs.flush()
    Assert.eq(picked, P2 .. "/AnkioTomas/moon/releases/download/v1.0.0/book.koplugin-v1.0.0.zip")
    Assert.eq(cfg.mirror_release_last, P2)
    Assert.is_true(Github.isDead(P1))
    Assert.is_false(Github.isDead(P2))

    reset()
    picked = nil
    Github.pickRelease(REL, function(u) picked = u end)
    Assert.len(calls, 0)
    Assert.len(probes, 2)
    probes[2].handlers.on_headers(200, headers(4096, "application/zip"))
    Stubs.flush()
    Assert.eq(picked, probes[2].url)
end

do -- 10. 已钉住 Release 源失效：切本地其余可用缓存，不查目录；新源胜出并拉黑旧源
    cfg.mirror_release_last, cfg.mirror_release, cfg.mirror_dead = P2, { P2, P3 }, {}
    reset()
    local picked
    Github.pickRelease(REL, function(u) picked = u end)
    probes[1].handlers.on_done("timeout")
    probes[2].handlers.on_done("timeout")
    Stubs.flush()
    Assert.len(calls, 0)
    Assert.len(probes, 4)
    probes[4].handlers.on_headers(200, headers(4096))
    Stubs.flush()
    Assert.eq(picked, probes[4].url)
    Assert.eq(cfg.mirror_release_last, P3)
    Assert.is_true(Github.isDead(P2))
end

do -- 11. Release 无缓存 / 全败：请求 MIRRORS_API 刷新；刷新中取消中断请求；接口不可达最终回落直连
    cfg.mirror_release_last, cfg.mirror_release, cfg.mirror_dead = "", { P1 }, {}
    reset()
    plan[Github.MIRRORS_API] = {
        body = '{"code":200,"data":{"release":["https://p1.example/https://github.com","https://p3.example/https://github.com"]}}',
    }
    local picked
    Github.pickRelease(REL, function(u) picked = u end)
    probes[1].handlers.on_done("timeout")
    probes[2].handlers.on_done("timeout")
    Stubs.flush()
    Assert.len(calls, 1)
    Assert.eq(calls[1], Github.MIRRORS_API)
    Assert.len(probes, 4)
    probes[4].handlers.on_headers(200, headers(4096))
    Stubs.flush()
    Assert.eq(picked, probes[4].url)

    -- 刷新期间取消
    cfg.mirror_release_last, cfg.mirror_release, cfg.mirror_dead = "", {}, {}
    reset()
    plan[Github.MIRRORS_API] = "hang"
    picked = nil
    local h = Github.pickRelease(REL, function(u) picked = u end)
    h.cancel()
    Stubs.flush()
    Assert.is_true(cancelled_urls[Github.MIRRORS_API])
    Assert.is_nil(picked)

    -- 目录失败 + 兜底探测全败：回落直连
    cfg.mirror_release_last, cfg.mirror_release, cfg.mirror_dead = "", {}, {}
    reset()
    plan[Github.MIRRORS_API] = "offline"
    Github.pickRelease(REL, function(u) picked = u end)
    Stubs.flush()
    Assert.len(probes, 1 + #Github.FALLBACK_RELEASE)
    for _idx, p in ipairs(probes) do p.handlers.on_done("timeout") end
    Stubs.flush()
    Assert.eq(picked, REL.url)
end
