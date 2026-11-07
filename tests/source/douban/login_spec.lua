--[[--
豆瓣登录会话：取消、坏跳转、换号和迟到响应不能污染有效账号。

@module tests.source.douban.login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
package.preload["json"] = function() return require("support.json_stub") end
local cfg = { cookie = "session=old", logged_in = true, user_id = "42" }
local requests, delayed, status, body, location = {}, false, 200, nil, nil
local next_status
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["http.request"] = function()
    return {
        headerAll = function() return { "session=new; Path=/; Secure; HttpOnly" } end,
        header = function() return location end,
        request = function(opts, cb)
            local req = { opts = opts }
            requests[#requests + 1] = req
            local res = { code = status, body = body or 'Ark.user = {"id":"42","isAnonymous":false,"name":"测试"}' }
            status, next_status = next_status or status, nil
            req.reply = function() cb(res, status == 0 and "network failed" or nil) end
            if not delayed then req.reply() end
            return { cancel = function() req.cancelled = true end }
        end,
    }
end
local Client = require("source.douban.client")
Client.load()
local ok, err
Client.newLogin("session=pasted"):checkCookieAsync(function(value, reason) ok, err = value, reason end)
Assert.is_true(ok)
Assert.eq(cfg.cookie, "session=new")
Assert.is_nil(cfg.cookie:find("Path", 1, true))
Assert.is_nil(cfg.cookie:find("HttpOnly", 1, true))
Assert.eq(requests[1].opts.headers.Cookie, "session=pasted")

body = 'Ark.user = {"id":"99","isAnonymous":false}'
Client.newLogin("session=other"):checkCookieAsync(function(value, reason) ok, err = value, reason end)
Assert.eq(ok, false)
Assert.matches(err, "先退出旧账号")
Assert.eq(cfg.user_id, "42")
Assert.eq(cfg.cookie, "session=new")

status, body = 0, nil
Client.newLogin("session=bad"):checkCookieAsync(function(value, reason) ok, err = value, reason end)
Assert.eq(ok, false)
Assert.eq(err, "network failed")
Assert.eq(cfg.logged_in, true)

status, location = 302, "https://untrusted.invalid/collect"
local before = #requests
Client.newLogin("session=bad"):checkCookieAsync(function(value, reason) ok, err = value, reason end)
Stubs.flush()
Assert.eq(ok, false)
Assert.eq(#requests, before + 1)
Assert.eq(cfg.cookie, "session=new")

status, location, next_status = 302, "https://accounts.arkread.com/oidc/login", 200
Client.newLogin("session=bad"):checkCookieAsync(function(value, reason) ok, err = value, reason end)
status, location = 200, nil
Stubs.flush()
Assert.eq(ok, false)
Assert.eq(cfg.cookie, "session=new")

body = 'Ark.user = {"id":"","isAnonymous":false}'
Client.newLogin("session=bad"):checkCookieAsync(function(value) ok = value end)
Assert.eq(ok, false)
body = 'Ark.user = {"id":{},"isAnonymous":false}'
Client.newLogin("session=bad"):checkCookieAsync(function(value) ok = value end)
Assert.eq(ok, false)
body = nil

status, location, delayed = 200, nil, true
local calls = 0
local login = Client.newLogin("session=cancel")
local job = login:checkCookieAsync(function() calls = calls + 1 end)
job.cancel()
login:cancel()
requests[#requests].reply()
Assert.eq(calls, 0)
Assert.eq(cfg.cookie, "session=new")

local stale = Client.newLogin("session=stale")
stale:checkCookieAsync(function(value, reason) ok, err = value, reason end)
local old = requests[#requests]
delayed = false
Client.newLogin("session=recent"):checkCookieAsync(function(value) Assert.is_true(value) end)
old.reply()
Assert.eq(ok, false)
Assert.eq(err, "登录状态已变化，请重试")
Assert.eq(cfg.cookie, "session=new")

cfg.user_id = nil
Client.newLogin("session=migration"):checkCookieAsync(function(value, reason) ok, err = value, reason end)
Assert.eq(ok, false)
Assert.matches(err, "先退出旧账号")
