--[[--
快看登录：官方账号校验、取消、旧账号迁移和受限微信回调。

@module tests.source.kuaikan.login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Text = require("utils.text")
package.loaded["json"] = JSON
local cfg, requests, saves = {}, {}, 0
local cleared = 0
package.loaded["source.logout"] = { clear = function(_id, clear)
    clear(); cleared = cleared + 1; return true
end }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saves = saves + 1 end,
}
package.loaded["source.auth"] = { ok = function() end }
local Request = {
    header = function(res, key) return res and res.headers and res.headers[key] end,
    headerAll = function(res, key) return res and res.headers and res.headers[key] or {} end,
    get = function(url, opts, cb)
        local request = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = request
        return { cancel = function() request.cancelled = true end }
    end,
}
package.loaded["http.request"] = Request
local Client = require("source.kuaikan.client")
local Mapper = require("source.kuaikan.mapper")
local Login = require("source.kuaikan.login")
local function account(id, authenticate)
    return JSON.encode({ code = 200, data = { user_info = { user_id = id, authenticate = authenticate or 1 } } })
end
local value, reason
local function answer(result, err) value, reason = result, err end
local function cookie(text)
    local session = Login.new()
    session:cookieAsync(text, answer)
    return session, requests[#requests]
end

local session, request = cookie("Cookie: sid=first")
Assert.eq(request.url, Client.ACCOUNT_URL)
Assert.eq(request.opts.headers.Cookie, "sid=first")
Assert.eq(request.opts.cache_ttl, 0)
Assert.is_nil(request.url:find("sid", 1, true))
Assert.is_nil(cfg.cookie)
request.cb(account(7))
Assert.eq(value.user_id, "7")
Assert.eq(cfg.cookie, "sid=first")
Assert.is_true(cfg.logged_in)
Assert.eq(saves, 1)

for _idx, response in ipairs({
    { raw = "broken" }, { raw = account(0) }, { raw = account(7, 0) },
    { raw = JSON.encode({ code = 200, data = { user_info = {} } }) },
    { raw = account("7.1") }, { raw = JSON.encode({ code = 500 }) }, { err = "offline" },
}) do
    session, request = cookie("sid=invalid")
    request.cb(response.raw, response.err)
    Assert.is_nil(value)
    Assert.is_true(type(reason) == "string")
    Assert.eq(cfg.cookie, "sid=first")
end
session, request = cookie("sid=other")
request.cb(account(8))
Assert.is_nil(reason)
Assert.eq(cfg.user_id, "8")
Assert.eq(cleared, 1)

local calls = 0
session = Login.new()
session:cookieAsync("sid=cancelled", function() calls = calls + 1 end)
request = requests[#requests]
session:cancel()
Assert.is_true(request.cancelled)
request.cb(account(7))
Assert.eq(calls, 0)
Assert.eq(cfg.cookie, "sid=other")

local _old, late = cookie("sid=old")
session, request = cookie("sid=latest")
request.cb(account(7))
late.cb(account(7))
Assert.eq(cfg.cookie, "sid=latest")
Assert.eq(reason, "登录状态已变化，请重试")
session, request = cookie("sid=after-logout")
cfg.cookie, cfg.user_id, cfg.logged_in = nil, nil, nil
Client.login_revision = Client.login_revision + 1
request.cb(account(7))
Assert.is_nil(cfg.cookie)

cfg = { cookie = "sid=legacy" }
session, request = cookie("sid=renewed")
local before = #requests
request.cb(account(7))
Assert.eq(#requests, before, "不再查询旧 Cookie")
Assert.eq(cfg.cookie, "sid=renewed")
Assert.eq(cfg.user_id, "7")
cfg = { cookie = "sid=legacy-other" }
session, request = cookie("sid=new")
request.cb(account(8))
Assert.eq(cfg.cookie, "sid=new")
Assert.eq(cfg.user_id, "8")
Assert.is_nil(reason)
cfg = { cookie = "sid=legacy-offline" }
session, request = cookie("sid=new")
request.cb(nil, "network")
Assert.eq(reason, "network")
Assert.eq(cfg.cookie, "sid=legacy-offline")
cfg = { cookie = "sid=legacy-expired" }
session, request = cookie("sid=new")
request.cb(account(8))
Assert.eq(cfg.user_id, "8")
Assert.eq(cfg.cookie, "sid=new", "旧账号失效不妨碍新账号登录")
Assert.is_nil(reason)

local redirect = "https://open.weixin.qq.com/connect/qrconnect?" .. Text.formEncode({
    appid = "wx92ba65b18ed55877", scope = "snsapi_login", response_type = "code",
    redirect_uri = Mapper.WECHAT_CALLBACK, state = "opaque+state",
})
Assert.eq(Mapper.qrLocation(redirect).state, "opaque+state")
Assert.is_nil(Mapper.qrLocation(redirect:gsub("wx92ba65b18ed55877", "wrong")))
Assert.is_nil(Mapper.qrLocation(redirect:gsub("open.weixin.qq.com", "evil.test")))
Assert.is_nil(Mapper.qrLocation(redirect .. "&state=another"))
Assert.eq(Mapper.qrStatus("window.wx_errcode=408; window.wx_code='';"), 408)
Assert.eq(Mapper.qrStatus(JSON.encode({ wx_errcode = 404 })), 404)
Assert.eq(select(2, Mapper.qrStatus(JSON.encode({ wx_errcode = 405, wx_code = "confirmed" }))), "confirmed")
Assert.is_nil(Mapper.qrStatus(JSON.encode({ wx_errcode = 405 })))

cfg = {}
session = Login.new()
local uuid
session:qrCreateAsync(function(id, err) uuid, reason = id, err end)
request = requests[#requests]
Assert.is_nil(request.opts.headers.Cookie)
request.cb(nil, "HTTP 302", { code = 302, headers = {
    Location = redirect,
    ["Set-Cookie"] = { "nonce=anonymous; Domain=.kuaikanmanhua.com; Path=/",
        "scoped=callback; Path=/v1/passport", "nested=api; PATH=/v2/",
        "evil=blocked; Domain=evil.test; Path=/" },
} })
request = requests[#requests]
Assert.eq(request.url, redirect)
Assert.is_nil(request.opts.headers.Cookie)
Assert.eq(request.opts.cache_ttl, 0)
request.cb('<img src="/connect/qrcode/test-uuid">')
Assert.eq(uuid, "test-uuid")
session:qrPollAsync(uuid, nil, function(status) value = status end)
request = requests[#requests]
Assert.is_nil(request.opts.headers.Cookie)
request.cb("window.wx_errcode=408;")
Assert.eq(value, 408)
session:exchangeAsync("confirmed", answer)
request = requests[#requests]
Assert.matches(request.url, "^https://www%.kuaikanmanhua%.com/v1/passport/login/pc/user_wechat_login_check%?")
Assert.matches(request.url, "state=opaque%%2Bstate")
Assert.eq(request.opts.headers.Cookie, "nonce=anonymous; scoped=callback")
request.cb(nil, "HTTP 302", { code = 302, headers = {
    Location = "/webs/loginh",
    ["Set-Cookie"] = { "sid=authorized; Domain=.kuaikanmanhua.com; Path=/",
        "nonce=; Path=/; Max-Age=0" },
} })
request = requests[#requests]
Assert.eq(request.opts.headers.Cookie, "sid=authorized")
request.cb("<html>callback complete</html>")
Assert.eq(requests[#requests].opts.headers.Cookie, "nested=api; sid=authorized")
requests[#requests].cb(account(7))
Assert.eq(value.user_id, "7")
Assert.eq(cfg.cookie, "nested=api; sid=authorized")
Assert.is_nil(cfg.cookie:find("evil", 1, true))
Assert.is_nil(cfg.cookie:find("scoped", 1, true))

cfg = {}
session = Login.new()
session.state = "test"
session:exchangeAsync("code", answer)
request = requests[#requests]
local count = #requests
request.cb(nil, "HTTP 302", { code = 302, headers = { Location = "https://evil.test/" } })
Assert.eq(#requests, count)
Assert.eq(reason, "登录响应无效")
Assert.is_nil(cfg.cookie)

local original_get = Request.get
Request.get = function(url, opts, cb)
    if url:find("/user_wechat_login?", 1, true) then
        cb(nil, "HTTP 302", { code = 302, headers = { Location = redirect } })
        return { cancel = function() error("cancelled completed initialization") end }
    end
    return original_get(url, opts, cb)
end
session = Login.new()
session:qrCreateAsync(function() calls = calls + 1 end)
request = requests[#requests]
session:cancel()
Assert.is_true(request.cancelled)
request.cb('<img src="/connect/qrcode/late">')
Assert.eq(calls, 0)

local expired
value, reason, expired = Client.accountResponse(nil, "HTTP 302", { code = 302, headers = { Location = "/webs/loginh?redirect=x" } })
Assert.is_true(expired)
value, reason, expired = Client.accountResponse(nil, "HTTP 302", { code = 302, headers = { Location = "/webs/loginhacker" } })
Assert.is_nil(expired)

Request.get = original_get
local expired_calls, image_calls = 0, 0
package.loaded["source.auth"] = {
    ok = function() end,
    expire = function() expired_calls = expired_calls + 1 end,
}
local function locked()
    cfg = { cookie = "sid=reader", user_id = "7", logged_in = true }
    local handle = Client.imagesAsync("locked", function(_urls, err) image_calls = image_calls + 1; reason = err end)
    requests[#requests].cb("ok", nil, { headers = { ["set-cookie"] = { "kk_s_t=challenge; Path=/" } } })
    requests[#requests].cb(JSON.encode({ code = 200, data = { comic_info = { locked = true } } }))
    Assert.eq(requests[#requests].opts.headers.Cookie, "sid=reader")
    return handle, requests[#requests]
end
local handle
handle, request = locked()
request.cb(account(7))
Assert.eq(reason, "本章未购买")
Assert.eq(expired_calls, 0)
handle, request = locked()
request.cb(account(0, 0))
Assert.eq(expired_calls, 1)
Assert.eq(reason, "快看登录已失效，请重新登录")
handle, request = locked()
cfg.cookie, cfg.user_id = "sid=new-account", "8"
request.cb(account(0, 0))
Assert.eq(expired_calls, 1)
Assert.eq(reason, "登录状态已变化，请重试")
handle, request = locked()
local before_calls = image_calls
handle.cancel()
Assert.is_true(request.cancelled)
request.cb(account(0, 0))
Assert.eq(image_calls, before_calls)
Assert.eq(expired_calls, 1)
