--[[--
掌阅取消在途下一阶段、坏响应与旧会话认证状态隔离。

@module tests.source.ireader.async_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg = { usr = "old", zysid = "old-session" }
package.loaded["utils.settings"] = { getSource = function() return cfg end }
local requests, mode = {}, "delayed"
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local request = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = request
        if url:find("/bookshelf/list", 1, true) and mode == "sync-shelf" then
            cb(JSON.encode({ code = 0, body = { data = {}, current_version = 1 } }))
        elseif url:find("page=1", 1, true) and mode == "sync-toc" then
            cb(JSON.encode({ code = 0, body = { list = { { id = 1 } }, page = { totalPage = 2 } } }))
        end
        return { cancel = function() request.cancelled = true end }
    end,
    post = function(url, body, opts, cb)
        local request = { url = url, body = body, opts = opts, cb = cb }
        requests[#requests + 1] = request
        return { cancel = function() request.cancelled = true end }
    end,
}
local Client = require("source.ireader.client")
local result, reason, calls = nil, nil, 0
local function done(value, err) result, reason, calls = value, err, calls + 1 end

Client.qrCreateAsync(done)
Assert.is_nil(requests[#requests].url:find("usr=old", 1, true))
Assert.eq(requests[#requests].opts.cache_ttl, 0)
Client.qrPollAsync("test-code", done)
Assert.is_nil(requests[#requests].url:find("old-session", 1, true))
Assert.eq(requests[#requests].opts.cache_ttl, 0)

mode = "sync-shelf"
local handle = Client.addAsync("42", "书", done)
local pending = requests[#requests]
local before = calls
handle:cancel()
Assert.is_true(pending.cancelled)
pending.cb(JSON.encode({ code = 0, body = true }))
Assert.eq(calls, before)

mode = "delayed"
Client.addAsync("42", "书", done)
pending = requests[#requests]
local count = #requests
cfg.usr, cfg.zysid = "new", "new-session"
pending.cb(JSON.encode({ code = 0, body = { data = {}, current_version = 1 } }))
Assert.eq(#requests, count, "会话变化不能用旧账号发加架请求")
Assert.is_nil(result)
Assert.eq(reason, "登录状态已变化，请重试")

local Auth = require("source.auth")
Auth.reset()
Client.get("/old-response", nil, done)
pending = requests[#requests]
cfg.zysid = "renewed"
pending.cb(JSON.encode({ code = 600001 }))
Assert.is_true(not Auth.expired("ireader"))
Assert.is_nil(result)
Client.get("/expired", nil, done)
requests[#requests].cb(JSON.encode({ code = 600001 }))
Assert.is_true(Auth.expired("ireader"))
Client.get("/stale-success", nil, done)
pending = requests[#requests]
cfg.zysid = "latest"
pending.cb(JSON.encode({ code = 0, body = {} }))
Assert.is_true(Auth.expired("ireader"), "旧会话成功不能清新会话的失效标记")

mode = "sync-toc"
handle = Client.chaptersAsync("42", done)
pending = requests[#requests]
before = calls
handle:cancel()
Assert.is_true(pending.cancelled)
pending.cb(JSON.encode({ code = 0, body = { list = {}, page = { totalPage = 2 } } }))
Assert.eq(calls, before)

mode = "delayed"
Client.chaptersAsync("42", done)
requests[#requests].cb(JSON.encode({ code = 0, body = {} }))
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Client.chaptersAsync("42", done)
requests[#requests].cb(JSON.encode({ code = 0, body = { list = {}, page = { totalPage = 3 } } }))
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Client.contentAsync("42", "1", done)
requests[#requests].cb(JSON.encode({ code = 0, body = true }))
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Client.shelfAsync(done)
requests[#requests].cb(JSON.encode({ code = 0, body = {} }))
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Auth.expire("ireader", "测试失效状态")
Client.checkSessionAsync({ usr = "candidate", zysid = "candidate-session" }, done)
Assert.is_true(requests[#requests].url:find("usr=candidate", 1, true) ~= nil)
requests[#requests].cb(JSON.encode({ code = 0, body = { data = {} } }))
Assert.is_true(result)
Assert.is_true(Auth.expired("ireader"), "候选登录校验不改变现有账号的认证状态")

local catalog_opts = { parent = "10", category = "11", order = "score", status = "0" }
Client.catalogAsync(catalog_opts, 2, done)
Assert.is_true(requests[#requests].url:find("currentPage=2", 1, true) ~= nil)
requests[#requests].cb(JSON.encode({ code = 0, html = "", body = { current_page = 2, page_total = 2 } }))
Assert.len(result, 0)
Client.catalogAsync(catalog_opts, 2, done)
requests[#requests].cb(JSON.encode({ code = 0, html = "<html>captcha</html>", body = { current_page = 2, page_total = 3 } }))
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Client.catalogAsync(catalog_opts, 2, done)
requests[#requests].cb(nil, "network failed")
Assert.eq(reason, "network failed")
