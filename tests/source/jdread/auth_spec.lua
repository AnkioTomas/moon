--[[--
京东扫码登录状态机离线用例。

@module tests.source.jdread.auth_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local cfg = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_, value) cfg = value end,
        ensureDeviceId = function() return "test-device" end,
    }
end

package.preload["utils.paths"] = function()
    return {
        ensureLayout = function() end,
        imageDir = function() return Config.dir() end,
    }
end

local calls = 0
local ticket_reply = '{"returnCode":0,"url":"https://e.m.jd.com/"}'
package.preload["http.request"] = function()
    local Request = {}
    function Request.randomUA() return "test-agent" end
    function Request.header(res, name)
        return res and res.headers and (res.headers[name] or res.headers[name:lower()])
    end
    function Request.get(url, _opts, cb)
        calls = calls + 1
        local res = { code = 200, headers = {} }
        if url:find("/show?", 1, true) then
            res.headers["Set-Cookie"] = {
                "QRCodeKey=qr-key; HttpOnly",
                "wlfstk_smdl=token; Domain=.jd.com",
            }
            cb("\137PNG\r\n\26\nstub", nil, res)
        elseif url:find("/check?", 1, true) then
            local callback = url:match("[?&]callback=([^&]+)")
            local code = calls == 2 and 201 or (calls == 3 and 202 or 200)
            local data = code == 200 and '{"code":200,"ticket":"ticket"}'
                or ('{"code":' .. code .. ',"msg":"waiting"}')
            cb(callback .. "(" .. data .. ")", nil, res)
        else
            res.headers["Set-Cookie"] = {
                "thor=session; Domain=.jd.com",
                "pin=tester; Domain=.jd.com",
            }
            cb(ticket_reply, nil, res)
        end
        return { cancel = function() end }
    end
    return Request
end

package.loaded["json"] = nil
package.loaded["utils.settings"] = nil
package.loaded["utils.paths"] = nil
package.loaded["http.request"] = nil
package.loaded["source.jdread.auth"] = nil

local Auth = require("source.jdread.auth")

do
    local started
    Auth.beginQrLoginAsync(function(value) started = value end)
    Assert.not_nil(started)
    Assert.eq(started.token, "token")

    local login_info
    Auth.waitQrLoginAsync(started.token, function(value, err, status)
        Assert.is_nil(err)
        Assert.eq(status, "ok")
        login_info = value
    end)
    Stubs.flush()
    Assert.eq(login_info.ticket, "ticket")

    local user, complete_err
    Auth.completeQrLoginAsync(login_info, function(value, err)
        user, complete_err = value, err
    end)
    Assert.is_nil(complete_err)
    Assert.eq(user.user_name, "tester")
    Assert.matches(cfg.cookie, "pin=tester")
    Assert.matches(cfg.cookie, "thor=session")
    Assert.is_false(cfg.cookie:find("QRCodeKey", 1, true) ~= nil)
    Assert.is_false(cfg.cookie:find("wlfstk_smdl", 1, true) ~= nil)
    Assert.matches(cfg.uuid, "^h5%x%x%x%x")
    Assert.is_true(Auth.hasSession())
end

do
    local uuid = cfg.uuid
    Auth.clearSession()
    Assert.is_false(Auth.hasSession())
    Assert.eq(cfg.uuid, uuid)
end

-- ticket 校验失败：按官方 returnCode 语义提示并附原始码，不写会话。
for reply, expected in pairs({
    ['{"returnCode":80}'] = "京东判定本次扫码存在风险，请稍后重试 (80)",
    ['{"returnCode":58}'] = "二维码已失效，请重新登录 (58)",
    ['{"returnCode":85}'] = "京东登录校验失败 (85)",
    ["<html>"] = "京东登录校验失败",
}) do
    ticket_reply = reply
    local user, err
    Auth.completeQrLoginAsync({ ticket = "ticket" }, function(value, e)
        user, err = value, e
    end)
    Assert.is_nil(user)
    Assert.eq(err, expected)
    Assert.is_false(Auth.hasSession())
end
