--[[--
http.mirror：模板展开、优先级（上次成功 → 默认，冷却垫底）、失败换源、HTML 拦截。
@module tests.http.mirror_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local cfg = { mirror_last = "" }
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
    -- 冷却中的源垫底
    Assert.eq(list[#list], Mirror.DEFAULTS[2])
    Assert.eq(list[#list - 1], Mirror.DEFAULTS[1])
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
