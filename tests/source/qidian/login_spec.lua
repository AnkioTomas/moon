--[[-- 起点短信候选会话：图形 / 短信 key、官方兑换、取消与同步回调。 @module tests.source.qidian.login_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Text = require("utils.text")
package.preload["json"] = function() return JSON end
package.preload["utils.random"] = function() return { hex = function() return "csrf" end } end
local responses, requests, cancelled, late = {}, {}, {}, nil
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            requests[#requests + 1] = opts
            local index, res = #requests, table.remove(responses, 1)
            if res.defer then late = function() cb(res, res.err) end else cb(res, res.err) end
            return { cancel = function() cancelled[#cancelled + 1] = index end }
        end,
        header = function(res, key) return (res.headers or {})[key] end,
        headerAll = function(res, key)
            local value = (res.headers or {})[key]
            return type(value) == "table" and value or (value and { value } or {})
        end,
    }
end
local Login = require("source.qidian.login")
local function wire(data)
    return { code = 200, body = JSON.encode({ code = 0, data = data }) }
end
local function params(index)
    local result = {}
    for key, value in requests[index].url:match("%?(.*)"):gmatch("([^&=]+)=([^&]*)") do
        result[key] = Text.urlDecode(value)
    end
    return result
end
local function reset() responses, requests, cancelled, late = {}, {}, {}, nil end

do
    reset()
    local init = wire({ sessionKey = "image-key", imgSrc = "https://ptlogin.yuewen.com/image" })
    init.headers = { ["Set-Cookie"] = { "al=anonymous; Path=/", "session=anonymous-session; Path=/" } }
    responses = { init, wire({ nextAction = 0, sessionKey = "sms-key" }),
        wire({ nextAction = 0, ticket = "ticket", ywGuid = "raw-guid", ywKey = "raw-key" }),
        { code = 302, headers = { Location = "/done", ["Set-Cookie"] = { "ywguid=321; Path=/", "ywkey=site-key; Path=/" } } },
        { code = 200, body = "OK" } }
    local session, cookie = Login.new()
    session:beginAsync(function(data) Assert.is_true(data ~= nil) end)
    session:sendCodeAsync("+86", "13800000000", "image-code", function(data) Assert.eq(data.nextAction, 0) end)
    session:verifyAsync("13800000000", "123456", function(value) cookie = value end)
    Assert.eq(params(2).sessionKey, "image-key")
    Assert.eq(params(2).validateCode, "image-code")
    Assert.eq(params(2).inputUserId, "+8613800000000")
    Assert.eq(params(2).phoneIsAbroad, "0")
    Assert.eq(params(2).auto, "anonymous")
    Assert.eq(params(3).sessionKey, "sms-key")
    Assert.eq(params(3).inputUserId, "13800000000", "官方短信提交不带国际区号")
    Assert.matches(cookie, "ywguid=321")
    Assert.matches(cookie, "ywkey=site%-key")
    Assert.matches(cookie, "_csrfToken=csrf")
    Assert.is_nil(cookie:find("anonymous", 1, true), "匿名登录域 Cookie 不保存为书源凭据")
    Assert.is_nil(requests[1].headers.Cookie:find("ywkey", 1, true), "候选会话不读已保存账号")
    Assert.eq(requests[3].allow_redirects, false)
end

do
    reset()
    responses = { wire({ nextAction = 11, sessionKey = "captcha-key",
        imgSrc = "https://turing.captcha.qcloud.com/TCaptcha.js?aid=1600000770" }),
        wire({ nextAction = 0, sessionKey = "sms" }) }
    local session = Login.new()
    session:sendCodeAsync("+852", "12345678", nil, function(data) Assert.eq(data.nextAction, 11) end)
    session:sendCodeAsync("+852", "12345678", "random;proof", function(data) Assert.eq(data.nextAction, 0) end)
    Assert.eq(params(2).sessionKey, "captcha-key")
    Assert.eq(params(2).validateCode, "random;proof")
    Assert.eq(params(1).phoneIsAbroad, "1")
    Assert.eq(session.sms_key, "sms")
end

do
    reset()
    responses = { { code = 200, body = "not json" }, wire({ nextAction = 99 }) }
    local session, err = Login.new()
    session:beginAsync(function(value, reason) Assert.is_nil(value); err = reason end)
    Assert.matches(err, "响应无效")
    session:sendCodeAsync("+86", "13800000000", nil, function(value, reason) Assert.is_nil(value); err = reason end)
    Assert.matches(err, "未支持")
end

do
    reset()
    responses = { wire({ nextAction = 0, ticket = "ticket", ywGuid = "123", ywKey = "raw" }),
        { code = 302, headers = { Location = "/done" } }, { code = 200, body = "OK", defer = true } }
    local session, called = Login.new(), false
    session.sms_key = "sms"
    session:verifyAsync("13800000000", "123456", function() called = true end)
    session:cancel()
    Assert.eq(cancelled[1], 3, "同步首段回调不能覆盖后续兑换的取消句柄")
    late()
    Assert.is_false(called)
    Assert.is_nil(session.sms_key)
    Assert.is_nil(next(session.webjar))
end

do
    reset()
    responses = { wire({ nextAction = 0, ["302url"] = "https://qidian.com.evil.example/x", ywGuid = "1", ywKey = "k" }) }
    local session, err = Login.new()
    session.sms_key = "sms"
    session:verifyAsync("13800000000", "123456", function(value, reason) Assert.is_nil(value); err = reason end)
    Assert.matches(err, "跳转地址无效")
    Assert.len(requests, 1)
end

do
    reset()
    responses = { { code = 200, body = "\137PNG\r\n\26\nimage" } }
    local image
    Login.new():imageAsync("/image", function(value) image = value end)
    Assert.matches(image, "^data:image/png;base64,")
end
