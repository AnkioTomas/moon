--[[--
http.mirror：模板展开、优先级（上次成功 → 默认，冷却垫底）、失败换源、HTML 拦截。
@module tests.http.mirror_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local cfg = { mirror_last = "", mirror_dead = {} }
package.preload["utils.settings"] = function()
    return {
        get = function(name) assert(name == "http"); return cfg end,
        save = function() end,
    }
end
package.loaded["utils.settings"] = nil

local calls, plan = {}, {}
package.preload["http.request"] = function()
    local function reply(url, cb, ...)
        calls[#calls + 1] = url
        local r = plan[url] or "ok"
        local args = { ... }
        require("ui/uimanager"):nextTick(function() cb(r, unpack(args)) end)
        return { cancel = function() end }
    end
    return {
        header = function(res, name) return res and res.headers and res.headers[name] end,
        get = function(url, _opts, cb)
            return reply(url, function(r)
                if r == "ok" then cb("{}", nil, {}) elseif r == "html" then cb("<html>", nil, { headers = { ["Content-Type"] = "text/html" } }) else cb(nil, r) end
            end)
        end,
        download = function(opts, _dest, cb)
            return reply(opts.url, function(r)
                if r == "ok" then cb(true, nil, {}) else cb(false, r) end
            end)
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["http.mirror"] = nil
local Mirror = require("http.mirror")

local function url(i, path) return (Mirror.DEFAULTS[i]:gsub("{path}", path)) end

do -- 默认首选 fastly，路径原样展开
    Assert.eq(Mirror.url("assets/a.png"), url(1, "assets/a.png"))
    Assert.is_true(Mirror.url("assets/a.png"):find("fastly%.jsdelivr%.net") ~= nil)
end

do -- 失败与 HTML 首页都换下一个源；成功源记为 mirror_last，下次优先
    local path = "assets/dict/manifest.json"
    plan[url(1, path)] = "timeout"
    plan[url(2, path)] = "html"
    local body
    Mirror.get(path, nil, function(b) body = b end)
    Stubs.flush()
    Assert.eq(body, "{}")
    Assert.eq(#calls, 3)
    Assert.eq(cfg.mirror_last, Mirror.DEFAULTS[3])
    -- 单地址（图片）用上次成功的源，不受冷却影响
    Assert.eq(Mirror.url("assets/a.png"), url(3, "assets/a.png"))
    local list = Mirror.templates()
    Assert.eq(list[1], Mirror.DEFAULTS[3])
    -- 同场有源成功：先失败的两个落盘拉黑，不再出现在候选里
    Assert.is_true(Mirror.isDead(Mirror.DEFAULTS[1]) and Mirror.isDead(Mirror.DEFAULTS[2]))
    Assert.eq(#list, #Mirror.DEFAULTS - 2)
    Assert.is_true(cfg.mirror_dead[Mirror.DEFAULTS[1]] ~= nil)
    -- 过期后解除
    cfg.mirror_dead[Mirror.DEFAULTS[1]] = os.time() - Mirror.DEAD_TTL - 1
    Assert.is_false(Mirror.isDead(Mirror.DEFAULTS[1]))
end

do -- 全部失败时回报最后的错误，check 不过也算失败
    calls = {}
    local ok, err
    Mirror.download("assets/x", { check = function() return false, "size mismatch" end }, os.tmpname(), function(a, b) ok, err = a, b end)
    Stubs.flush()
    Assert.is_false(ok)
    Assert.eq(err, "size mismatch")
    Assert.eq(#calls, #Mirror.templates())
end

do -- 同步失败立刻换源时，cancel 取消的是正在进行的那个请求
    package.loaded["http.mirror"] = nil
    local M = require("http.mirror")
    local cancelled, n = {}, 0
    local handle = (function()
        local chainStart = function(url, next_cb)
            n = n + 1
            local me = n
            if me == 1 then next_cb("sync fail") end
            return { cancel = function() cancelled[#cancelled + 1] = me end }
        end
        return chainStart
    end)()
    -- 通过 download 走 chain：桩 Request.download 换成同步首败
    local Req = require("http.request")
    local orig = Req.download
    Req.download = function(opts, _dest, cb) return handle(opts.url, function(err) if err then cb(false, err) end end) end
    local h = M.download("assets/sync.bin", {}, "/tmp/__mirror_sync_spec", function() end)
    h.cancel()
    Req.download = orig
    Assert.eq(#cancelled, 1)
    Assert.eq(cancelled[1], 2)
end
