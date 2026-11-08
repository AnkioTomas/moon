--[[--
知乎扫码会话、状态解析、Cookie 校验与取消。

@module tests.source.zhihu.login_spec
--]]
---@diagnostic disable: undefined-field

package.loaded["json"] = nil
package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Settings = require("utils.settings")
local Log = require("utils.log")
local original_warn, warnings = Log.warn, {}
Log.warn = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    warnings[#warnings + 1] = table.concat(parts, " ")
end
local posts, gets = {}, {}
local response, response_err = { status = 0 }, nil
local poll_cookies
local me = { id = "fixture-user" }
local defer_me, pending_me, cancelled_me
local defer_captcha, pending_captcha, cancelled_captcha
local navigation_error, missing_device, bad_create
local serial = 0

local function cookies(lines)
    return { code = 200, headers = { ["Set-Cookie"] = lines } }
end

package.loaded["http.request"] = {
    headerAll = function(res, name)
        local value = res and res.headers and res.headers[name]
        if type(value) == "string" then return { value } end
        return value or {}
    end,
    post = function(url, body, opts, cb)
        posts[#posts + 1] = { url = url, body = body, opts = opts }
        if url:find("/udid", 1, true) then
            cb("not-a-device-cookie", nil, cookies({}))
        elseif url:find("/login/qrcode", 1, true) then
            cb(Json.encode(bad_create or {
                token = "tok" .. serial, link = "https://www.zhihu.com/account/scan/" .. serial .. "?/api/login/qrcode",
                expires_at = 1800000000,
            }), nil, cookies({}))
        else
            error("unexpected POST " .. url)
        end
        return { cancel = function() end }
    end,
    get = function(url, opts, cb)
        gets[#gets + 1] = { url = url, opts = opts }
        if url:find("/signin", 1, true) then
            serial = serial + 1
            if navigation_error then cb(nil, navigation_error); return { cancel = function() end } end
            cb(nil, "HTTP 302", {
                code = 302, headers = {
                    Location = "/account/unhuman?type=fixture",
                    ["Set-Cookie"] = { "sec_token=sec" .. serial .. "; Path=/", "_xsrf=xsrf" .. serial .. "; Path=/" },
                },
            })
        elseif url:find("/account/unhuman", 1, true) then
            cb("<html></html>", nil, cookies({ "_zap=zapfix; Path=/" }))
        elseif url:find("/captcha/v2", 1, true) then
            local function reply()
                cb("{}", nil, cookies(missing_device and {} or { 'd_c0="dc' .. serial .. '"; Path=/' }))
            end
            if defer_captcha then
                pending_captcha = reply
                return { cancel = function() cancelled_captcha = true end }
            end
            reply()
        elseif url:find("/scan_info", 1, true) then
            cb(response_err and nil or Json.encode(response), response_err, {
                code = response_err and 403 or 200, body = Json.encode(response),
                headers = { ["Set-Cookie"] = poll_cookies },
            })
        elseif url:find("/api/v4/me", 1, true) then
            if defer_me then
                pending_me = function() cb(Json.encode(me), nil, { code = 200 }) end
                return { cancel = function() cancelled_me = true end }
            end
            cb(Json.encode(me), nil, { code = 200 })
        else
            error("unexpected GET " .. url)
        end
        return { cancel = function() end }
    end,
}
package.loaded["source.zhihu.client"] = nil
local Client = require("source.zhihu.client")
local cfg = Settings.getSource("zhihu")
local original_cookie = cfg.cookie
cfg.cookie = nil

local session, failure
Client.qrCreateAsync(function(value, err) session, failure = value, err end)
Assert.is_nil(failure)
Assert.eq(session.token, "tok1")
Assert.eq(session.link, "https://www.zhihu.com/account/scan/1")
Assert.eq(session.expires_at, 1800000000)
Assert.eq(posts[1].url, "https://www.zhihu.com/udid")
Assert.eq(posts[1].body, "{}")
Assert.eq(posts[1].opts.headers["x-xsrftoken"], "xsrf1")
Assert.eq(posts[2].body, "{}")
Assert.eq(posts[2].opts.content_type, "application/json;charset=UTF-8")
Assert.eq(posts[2].opts.headers["x-xsrftoken"], "xsrf1")
Assert.is_true(posts[2].opts.headers.Cookie:find('d_c0="dc1"', 1, true) ~= nil)
Assert.is_nil(posts[2].opts.headers["x-zse-83"])
Assert.eq(gets[1].url, "https://www.zhihu.com/signin")
Assert.is_nil(gets[1].opts.headers["x-requested-with"])
Assert.eq(gets[2].url, "https://www.zhihu.com/account/unhuman?type=fixture")
Assert.is_true(posts[2].opts.headers.Cookie:find("_zap=zapfix", 1, true) ~= nil)

local other
Client.qrCreateAsync(function(value) other = value end)
local kind, extra, poll_err
local function poll(value, err)
    response, response_err = value, err
    return Client.qrPollAsync(session, function(a, b, c) kind, extra, poll_err = a, b, c end)
end
poll({ status = 0 })
Assert.eq(kind, "wait")
Assert.is_nil(poll_err)
Assert.is_true(gets[#gets].opts.headers.Cookie:find('d_c0="dc1"', 1, true) ~= nil, "后建的码不能覆盖旧会话")
Assert.eq(other.jar.d_c0, '"dc2"')
poll({ login_status = "SCANNED", status = 1 })
Assert.eq(kind, "scanned")
Assert.is_nil(cfg.cookie)
poll({ status = 1 })
Assert.eq(kind, "scanned", "已扫码不等于已确认")
poll({ login_status = "CONFIRMED", cookie = "z_c0=confirmed; Path=/; Domain=.zhihu.com" })
Assert.eq(kind, "ok")
Assert.is_true(cfg.cookie:find("z_c0=confirmed", 1, true) ~= nil)
Assert.is_nil(session.jar.Path, "Cookie 属性不能作为凭证发送")
Assert.eq(gets[#gets].url, "https://www.zhihu.com/api/v4/me")

local saved = cfg.cookie
me = { error = { message = "rejected" } }
poll({ login_status = "CONFIRMED", cookie = "z_c0=rejected; Path=/" })
Assert.is_nil(kind)
Assert.is_true(poll_err ~= nil)
Assert.eq(cfg.cookie, saved, "校验失败保留已有登录")
me = { id = "fixture-user" }

poll({ status = 5, new_token = { token = "new", link = "https://www.zhihu.com/scan/new?/api/login/qrcode" } })
Assert.eq(kind, "refresh")
Assert.eq(extra.token, "new")
Assert.eq(extra.link, "https://www.zhihu.com/scan/new")
Assert.eq(extra.jar, session.jar)
poll({ login_status = "EXPIRED" })
Assert.eq(kind, "expired")
poll({ status = 5, new_token = { token = "", link = "" } })
Assert.eq(kind, "expired")
poll({}, "connection reset")
Assert.is_nil(kind)
Assert.eq(poll_err, "connection reset")
poll({ error = { code = 40352, message = "网络环境异常",
    redirect = "https://www.zhihu.com/account/unhuman?session=challenge%2Bfixture" } }, "HTTP 403")
Assert.eq(kind, "verify")
Assert.eq(extra, session)
Assert.eq(extra.challenge_id, "challenge+fixture")
Assert.eq(poll_err, "知乎需要安全验证，请在网页完成验证后继续扫码登录")
poll({ login_status = "UNKNOWN", cookie = "z_c0=private-cookie; Path=/" })
Assert.is_nil(kind)
Assert.eq(poll_err, "知乎登录响应异常，请重新获取二维码")
Assert.matches(warnings[#warnings], "poll HTTP 200")
Assert.matches(warnings[#warnings], "login_status=string")
Assert.is_nil(warnings[#warnings]:find("private-cookie", 1, true))
poll_cookies = { "z_c0=header-cookie; Path=/; HttpOnly" }
poll({ status = 1 })
Assert.eq(kind, "ok", "兼容旧版确认状态与 Set-Cookie 凭证")
Assert.is_true(cfg.cookie:find("z_c0=header-cookie", 1, true) ~= nil)
saved = cfg.cookie
poll_cookies = nil

local oauth = {
    access_token = "fixture-access", refresh_token = "fixture-refresh",
    token_type = "bearer", expires_in = 15552000, uid = "fixture-user", user_id = 123,
}
session.jar.z_c0 = nil
poll(oauth)
Assert.is_nil(kind, "OAuth 令牌不能替代登录 Cookie")
Assert.eq(cfg.cookie, saved)
poll_cookies = { "z_c0=oauth-cookie; Path=/; HttpOnly" }
poll(oauth)
Assert.eq(kind, "ok", "扫码确认直接返回 OAuth 令牌，不带状态字段")
Assert.is_nil(poll_err)
Assert.eq(gets[#gets].url, "https://www.zhihu.com/api/v4/me")
Assert.is_true(cfg.cookie:find("z_c0=oauth-cookie", 1, true) ~= nil)
Assert.is_nil(cfg.cookie:find("fixture-access", 1, true), "不持久化 OAuth 令牌")
saved = cfg.cookie
me = { error = { message = "rejected" } }
poll_cookies = { "z_c0=invalid-oauth-cookie; Path=/; HttpOnly" }
poll(oauth)
Assert.is_nil(kind)
Assert.not_nil(poll_err)
Assert.eq(cfg.cookie, saved, "OAuth 响应仍须校验用户身份")
me = { id = "fixture-user" }

defer_me = true
poll_cookies = { "z_c0=cancelled; Path=/; HttpOnly" }
local handle = poll(oauth)
handle.cancel()
Assert.is_true(cancelled_me, "同步轮询回调后，取消仍然要取消后续校验请求")
pending_me()
Assert.eq(cfg.cookie, saved, "取消校验后不能保存登录")
defer_me = false
poll_cookies = nil

defer_captcha = true
local called = false
handle = Client.qrCreateAsync(function() called = true end)
local count = #posts
handle.cancel()
Assert.is_true(cancelled_captcha, "取消必须指向当前在途请求")
pending_captcha()
Assert.is_false(called)
Assert.eq(#posts, count)
defer_captcha = false

navigation_error = "offline"
Client.qrCreateAsync(function(value, err) session, failure = value, err end)
Assert.is_nil(session)
Assert.eq(failure, "offline")
navigation_error = nil
missing_device = true
Client.qrCreateAsync(function(value, err) session, failure = value, err end)
Assert.is_nil(session)
Assert.eq(failure, "知乎未下发登录会话，请重新获取二维码", "不把 udid 响应正文冒充设备 Cookie")
missing_device = false
bad_create = { token = "private-token", link = "" }
Client.qrCreateAsync(function(value, err) session, failure = value, err end)
Assert.is_nil(session)
Assert.eq(failure, "知乎登录响应异常，请重新获取二维码")
Assert.matches(warnings[#warnings], "create HTTP 200")
Assert.matches(warnings[#warnings], "token=string")
Assert.is_nil(warnings[#warnings]:find("private-token", 1, true))

Log.warn = original_warn
cfg.cookie = original_cookie
Settings.saveSource("zhihu")
