--[[--
晋江多阶段请求取消、收藏读回、登录竞态与密码不落盘。

@module tests.source.jjwxc.async_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local cfg, requests, synchronous, saved = { cookie = "sid=test", token = "old" }, {}, nil, 0
package.loaded["json"] = JSON
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saved = saved + 1 end,
}
local expired = 0
package.loaded["source.auth"] = { ok = function() end, expire = function(_id, msg) expired = expired + 1; return msg end }
local Request = {
    get = function(url, opts, cb)
        local request = { url = url, cb = cb, opts = opts }
        request.cancel = function() request.cancelled = true end
        requests[#requests + 1] = request
        if synchronous then synchronous(request, #requests) end
        return request
    end,
    header = function(res, key) return res and res.headers and res.headers[key] end,
}
package.loaded["http.request"] = Request
package.loaded["utils.charset"] = { toUtf8 = function(raw) return raw end }
package.loaded["source.jjwxc.protocols.web"] = nil
local Web = require("source.jjwxc.protocols.web")
local fav = '<ul id="favul"><li><a href="/book2/1">测试书</a></li></ul>'

local called
synchronous = function(request, index) if index == 1 then request.cb(fav) end end
local handle = Web.shelfAsync(function() called = true end)
Assert.len(requests, 2)
handle.cancel()
Assert.is_true(requests[2].cancelled)
requests[2].cb('<ul id="favul"></ul>')
Assert.is_nil(called)

requests, synchronous = {}, nil
local result, reason
Web.shelfAsync(function(value, err) result, reason = value, err end)
requests[1].cb(fav)
requests[2].cb(fav)
Assert.is_nil(result)
Assert.eq(reason, "晋江收藏页无法解析", "重复页不能伪装完整书架")

requests = {}
Web.favRemoveAsync("1", function(value, err) result, reason = value, err end)
requests[1].cb("<html>HTTP 200 但未删除</html>")
requests[2].cb(fav)
requests[3].cb('<ul id="favul"></ul>')
Assert.is_nil(result)
Assert.eq(reason, "晋江没有确认取消收藏")
requests = {}
Web.favRemoveAsync("1", function(value, err) result, reason = value, err end)
requests[1].cb("<html>已执行</html>")
requests[2].cb('<ul id="favul"></ul>')
Assert.is_true(result)
Assert.eq(requests[1].opts.cache_ttl, 0)

requests = {}
Web.favAsync(cfg.cookie, function() end)
cfg.cookie = "sid=new"
requests[1].cb(nil, "HTTP 302", { code = 302, headers = { Location = "/my/login" } })
Assert.eq(expired, 0, "旧 Cookie 迟到不能使新登录过期")
Web.favAsync(cfg.cookie, function() end)
requests[2].cb(nil, "网络故障")
Assert.eq(expired, 0, "网络错误不能使登录过期")

requests, synchronous = {}, function(request, index)
    if index == 1 then request.cb(JSON.encode({ code = 1004 })) end
end
package.loaded["source.jjwxc.protocols"] = { current = function() return {
    contentAsync = function(_novel, _chapter, cb)
        local request = { cb = cb, cancel = function() called = "cancelled" end }
        requests[#requests + 1] = request
        return request
    end,
} end }
package.loaded["source.jjwxc.client"] = nil
called = nil
local Client = require("source.jjwxc.client")
handle = Client.contentAsync("1", "2", function() called = "late" end)
handle.cancel()
Assert.eq(called, "cancelled")
requests[2].cb("测试正文")
Assert.eq(called, "cancelled")

requests, synchronous = {}, nil
package.loaded["source.jjwxc.protocols.app"] = nil
local App = require("source.jjwxc.protocols.app")
App.save("test", "do-not-store", "old")
Assert.is_nil(cfg.password)
cfg.password = "legacy"
Assert.eq(App.get(), "old")
Assert.is_nil(cfg.password)
Assert.eq(saved, 2)
App.shelfAsync(function(value, err) result, reason = value, err end)
cfg.token = "new"
requests[1].cb(JSON.encode({ code = 1004 }))
Assert.matches(requests[2].url, "token=new")
requests[2].cb(JSON.encode({ addData = {} }))
Assert.len(result, 0)
Assert.eq(expired, 0)
requests = {}
App.shelfAsync(function(value, err) result, reason = value, err end)
requests[1].cb(nil, "网络故障")
Assert.eq(reason, "网络故障")
Assert.eq(expired, 0)
