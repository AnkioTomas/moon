--[[--
拷贝漫画 App 客户端：常量与令牌失效自动重登。

@module tests.source.copymanga.client_spec
--]]

local Assert = require("support.assert")

-- 记录请求；get 按队列回放 { code, body }，request 是登录 POST。
local gets, logins, replies, login_ok = {}, 0, {}, true
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        gets[#gets + 1] = { url = url, auth = opts.headers.Authorization }
        local reply = table.remove(replies, 1)
        if reply.code == 200 then
            cb(reply.body, nil, { code = 200, body = reply.body })
        else
            cb(nil, "HTTP " .. reply.code, { code = reply.code, body = reply.body })
        end
        return { cancel = function() end }
    end,
    request = function(_opts, cb)
        logins = logins + 1
        local body = login_ok
            and '{"code":200,"results":{"token":"fresh","user_id":"1","username":"user"}}'
            or '{"code":400,"message":"密码错误"}'
        cb({ code = 200, body = body })
        return { cancel = function() end }
    end,
}
package.loaded["json"] = { decode = require("support.json_stub").decode }
package.loaded["source.copymanga.auth"] = nil
package.loaded["source.copymanga.client"] = nil
local Client = require("source.copymanga.client")

do
    Assert.eq(Client.normalizeBaseUrl(""), Client.DEFAULT_BASE_URL)
    Assert.eq(Client.normalizeBaseUrl("https://api.example.com/"), "https://api.example.com")
    Assert.eq(Client.normalizeBaseUrl("https://copy4000.com"), "https://copy4000.com")
end

do
    local headers = Client.headers("abc")
    Assert.eq(headers["User-Agent"], "COPY/3.0.0")
    Assert.eq(headers.platform, "1")
    Assert.eq(headers.Authorization, "Token abc")
    Assert.is_nil(Client.headers("").Authorization)
end

do
    local client = Client:new({})
    Assert.eq(client.base_url, Client.DEFAULT_BASE_URL)
    Assert.is_true(client:configured())
end

local settings = require("utils.settings")
local function session(password)
    local cfg = settings.getSource("copymanga")
    cfg.token, cfg.username, cfg.password = "stale", "user", password
    settings.saveSource("copymanga", cfg)
end
local INVALID = '{"code":401,"message":"Invalid token header. Please login again."}'
local OK = '{"code":200,"results":{"list":[],"total":0}}'

-- #42：令牌被挤掉后返回 401，用保存的账号密码重登一次，换新令牌重试。
do
    session("secret")
    gets, logins, replies, login_ok = {}, 0, { { code = 401, body = INVALID }, { code = 200, body = OK } }, true
    local client = Client:new(settings.getSource("copymanga"))
    local wire, err
    client:collectAllAsync(function(rows, e) wire, err = rows, e end)
    Assert.is_nil(err)
    Assert.len(wire, 0)
    Assert.eq(logins, 1)
    Assert.len(gets, 2)
    Assert.eq(gets[1].auth, "Token stale")
    Assert.eq(gets[2].auth, "Token fresh")
    Assert.eq(client.token, "fresh")
end

-- 重登后仍 401：只重登一次，不死循环，给出可读提示而不是「HTTP 401」。
do
    session("secret")
    gets, logins, replies, login_ok = {}, 0, { { code = 401, body = INVALID }, { code = 401, body = INVALID } }, true
    local err
    Client:new(settings.getSource("copymanga")):collectAllAsync(function(_rows, e) err = e end)
    Assert.eq(logins, 1)
    Assert.eq(err, "拷贝漫画登录已失效，请在设置里重新登录")
end

-- 重登失败（密码已改）或没存密码：直接提示重新登录。
do
    session("secret")
    gets, logins, replies, login_ok = {}, 0, { { code = 401, body = INVALID } }, false
    local err
    Client:new(settings.getSource("copymanga")):collectAllAsync(function(_rows, e) err = e end)
    Assert.eq(logins, 1)
    Assert.eq(err, "拷贝漫画登录已失效，请在设置里重新登录")

    session("")
    gets, logins, replies = {}, 0, { { code = 401, body = INVALID } }
    Client:new(settings.getSource("copymanga")):collectAllAsync(function(_rows, e) err = e end)
    Assert.eq(logins, 0)
    Assert.eq(err, "拷贝漫画登录已失效，请在设置里重新登录")
end

require("source.copymanga.auth").clearSession()
package.loaded["http.request"] = nil

return true
