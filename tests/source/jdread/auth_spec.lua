--[[--
京东扫码登录状态机离线用例。

@module tests.source.jdread.auth_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

---@type table<string, any>
local cfg = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_, value) cfg = value end,
    }
end
package.preload["utils.device_id"] = function()
    return { ensure = function() return "test-device" end }
end

package.preload["utils.paths"] = function()
    return {
        ensureLayout = function() end,
        imageDir = function() return Config.dir() end,
    }
end

local calls = 0
local ticket_reply = '{"returnCode":0,"url":"https://e.m.jd.com/"}'
-- 配对模式：每张码发不同 token，check 像线上一样校验 token 与 Cookie 里的 wlfstk_smdl 一致。
local paired, shows = false, 0
-- hop：校验这一跳不带 Set-Cookie，会话在 url / Location 上。
local hop_mode = nil
local hop_urls = {}
package.preload["http.request"] = function()
    local Request = {}
    function Request.randomUA() return "test-agent" end
    function Request.header(res, name)
        return res and res.headers and (res.headers[name] or res.headers[name:lower()])
    end
    function Request.get(url, opts, cb)
        calls = calls + 1
        local res = { code = 200, headers = {} }
        if url:find("/show?", 1, true) then
            shows = shows + 1
            local token = paired and ("token-" .. shows) or "token"
            res.headers["Set-Cookie"] = {
                "QRCodeKey=qr-" .. token .. "; HttpOnly",
                "wlfstk_smdl=" .. token .. "; Domain=.jd.com",
            }
            cb("\137PNG\r\n\26\nstub", nil, res)
        elseif url:find("/check?", 1, true) and paired then
            local callback = url:match("[?&]callback=([^&]+)")
            local token = url:match("[?&]token=([^&]+)")
            local cookie = opts.headers.Cookie or ""
            local data = cookie:find("wlfstk_smdl=" .. token, 1, true)
                and ('{"code":200,"ticket":"ticket-' .. token .. '"}')
                or '{"code":257,"msg":"参数异常，请退出重试"}'
            cb(callback .. "(" .. data .. ")", nil, res)
        elseif url:find("/check?", 1, true) then
            local callback = url:match("[?&]callback=([^&]+)")
            local code = calls == 2 and 201 or (calls == 3 and 202 or 200)
            local data = code == 200 and '{"code":200,"ticket":"ticket"}'
                or ('{"code":' .. code .. ',"msg":"waiting"}')
            cb(callback .. "(" .. data .. ")", nil, res)
        elseif url:find("qrCodeTicketValidation", 1, true) then
            if hop_mode == "merged" then
                -- 多条 Set-Cookie 被合并成一行，expires 里自带逗号。
                res.headers["Set-Cookie"] = "thor=session; expires=Wed, 21 Oct 2026 07:28:00 GMT; Domain=.jd.com, "
                    .. "pin=tester; Path=/, pt_key=key; expires=Thu, 22 Oct 2026 07:28:00 GMT"
            elseif hop_mode == "junk" or hop_mode == "relay" then
                res.headers["Set-Cookie"] = { "__jda=track; Domain=.jd.com" }
            elseif not hop_mode then
                res.headers["Set-Cookie"] = {
                    "thor=session; Domain=.jd.com",
                    "pin=tester; Domain=.jd.com",
                }
            end
            cb(ticket_reply, nil, res)
        elseif hop_mode == "junk" then
            hop_urls[#hop_urls + 1] = url
            res.headers["Set-Cookie"] = { "__jdb=track; Domain=.jd.com" }
            cb("<html></html>", nil, res)
        elseif hop_mode == "relay" and url == "http://passport.jd.com/relay/loginRelay" then
            res.code = 302
            res.headers.Location = "https://passport.jd.com/relay/loginRelay"
            cb(nil, "HTTP 302", res)
        elseif hop_mode == "relay" and url == "https://passport.jd.com/relay/loginRelay" then
            cb('<script>window.location.href = "https://e.m.jd.com/relay-done";</script>', nil, res)
        elseif hop_mode == "relay" and not url:find("relay-done", 1, true) then
            cb("<html></html>", nil, res)
        elseif hop_mode == "redirect" and url:find("e.m.jd.com", 1, true) and not url:find("/home", 1, true) then
            res.code = 302
            res.headers.Location = "https://e.m.jd.com/home"
            res.headers["Set-Cookie"] = { "thor=session; Domain=.jd.com" }
            cb(nil, "HTTP 302", res)
        else
            res.headers["Set-Cookie"] = {
                "thor=session; Domain=.jd.com",
                "pin=tester; Domain=.jd.com",
            }
            cb("<html></html>", nil, res)
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
    Auth.waitQrLoginAsync(started, function(value, err, status)
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
    Auth.completeQrLoginAsync({ ticket = "ticket", jar = {} }, function(value, e)
        user, err = value, e
    end)
    Assert.is_nil(user)
    Assert.eq(err, expected)
    Assert.is_false(Auth.hasSession())
end

-- 两次登录并存（点外部关框后重进 / 连点）：旧轮询必须用自己那张码的 Cookie，
-- 串用新码的 wlfstk_smdl 时京东回 257“参数异常，请退出重试”。
do
    paired, shows = true, 0
    local first, second
    Auth.beginQrLoginAsync(function(value) first = value end)
    Auth.beginQrLoginAsync(function(value) second = value end)
    Assert.eq(first.token, "token-1")
    Assert.eq(second.token, "token-2")

    local results = {}
    for _, started in ipairs({ first, second }) do
        Auth.waitQrLoginAsync(started, function(value, err, status)
            results[#results + 1] = { info = value, err = err, status = status }
        end)
    end
    Stubs.flush()
    Assert.len(results, 2)
    for i, result in ipairs(results) do
        Assert.is_nil(result.err)
        Assert.eq(result.status, "ok")
        Assert.eq(result.info.ticket, "ticket-token-" .. i)
    end
    Assert.eq(results[1].info.jar.QRCodeKey, "qr-token-1")
end

-- 校验成功但这一跳没会话 cookie：跟 JSON.url 拿 thor。
do
    hop_mode = "url"
    ticket_reply = '{"returnCode":0,"url":"https://e.m.jd.com/"}'
    Auth.clearSession()
    local user, err
    Auth.completeQrLoginAsync({ ticket = "ticket", jar = { wlfstk_smdl = "token" } }, function(value, e)
        user, err = value, e
    end)
    Assert.is_nil(err)
    Assert.eq(user.user_name, "tester")
    Assert.matches(cfg.cookie, "thor=session")
    Assert.matches(cfg.cookie, "pin=tester")
    Assert.is_false(cfg.cookie:find("wlfstk_smdl", 1, true) ~= nil)
end

-- 跳转 302 的 Set-Cookie 也算会话，不能等 turbo 跟完才读头。
do
    hop_mode = "redirect"
    Auth.clearSession()
    local user, err
    Auth.completeQrLoginAsync({ ticket = "ticket", jar = {} }, function(value, e)
        user, err = value, e
    end)
    Assert.is_nil(err)
    Assert.matches(cfg.cookie, "thor=session")
end

-- 多条 Set-Cookie 合并成一行（逗号分隔，expires 内含逗号）：每条都要进 jar。
do
    hop_mode = "merged"
    ticket_reply = '{"returnCode":0,"url":"https://e.m.jd.com/"}'
    Auth.clearSession()
    local user, err
    Auth.completeQrLoginAsync({ ticket = "ticket", jar = {} }, function(value, e) user, err = value, e end)
    Assert.is_nil(err)
    Assert.matches(cfg.cookie, "thor=session")
    Assert.matches(cfg.cookie, "pin=tester")
    Assert.matches(cfg.cookie, "pt_key=key")
    Assert.is_false(cfg.cookie:find("GMT", 1, true) ~= nil)
end

-- 只有埋点 cookie 不算登录成功：跳转有上限，最终报错且不写会话。
do
    hop_mode = "junk"
    hop_urls = {}
    Auth.clearSession()
    local user, err
    Auth.completeQrLoginAsync({ ticket = "ticket", jar = {} }, function(value, e) user, err = value, e end)
    Assert.is_nil(user)
    Assert.eq(err, "登录未拿到会话 Cookie")
    Assert.is_false(Auth.hasSession())
    Assert.is_true(#hop_urls <= 5)
end

-- 日志里的真实链路：data.url 是 http relay → 302 https relay → 200 中转页 JS 跳转 → 拿到 thor。
do
    hop_mode = "relay"
    ticket_reply = '{"returnCode":0,"url":"http://passport.jd.com/relay/loginRelay"}'
    Auth.clearSession()
    local user, err
    Auth.completeQrLoginAsync({ ticket = "ticket", jar = {} }, function(value, e) user, err = value, e end)
    Assert.is_nil(err)
    Assert.matches(cfg.cookie, "thor=session")
end

do
    Assert.is_false(Auth._hasLoginCookie({ __jda = "x", QRCodeKey = "y" }))
    Assert.is_true(Auth._hasLoginCookie({ pt_key = "k" }))
    Assert.eq(Auth._pageRedirect('<meta http-equiv="refresh" content="0;url=https://e.m.jd.com/a?x=1&amp;y=2">'),
        "https://e.m.jd.com/a?x=1&y=2")
    -- 协议相对跳转（loginRelay 页里的 //aq.jd.com/...）不能拼到 passport 后面
    Assert.eq(Auth._absUrl("https://passport.jd.com/relay/loginRelay", "//aq.jd.com/certified/index"),
        "https://aq.jd.com/certified/index")
    Assert.eq(Auth._absUrl("https://passport.jd.com/a", "/b"), "https://passport.jd.com/b")
end

-- 浏览器授权只导入适用于 e.m.jd.com 的京东会话 Cookie，并先用签名 API 校验。
do
    local request, response, response_err, saved, api_calls = nil, nil, nil, false, 0
    package.loaded["source.jdread.client"] = nil
    package.preload["source.jdread.client"] = function()
        return {
            new = function(_, options)
                request = options
                return {
                    apiGetAsync = function(_, path, extra, cb)
                        api_calls = api_calls + 1
                        Assert.eq(path, "/jdread/api/bookshelf/sort")
                        Assert.is_nil(extra)
                        cb(response, response_err)
                        return { cancel = function() end }
                    end,
                }
            end,
        }
    end
    package.loaded["utils.settings"] = nil
    package.preload["utils.settings"] = function()
        return {
            getSource = function() return cfg end,
            saveSource = function(_, value) cfg, saved = value, true end,
        }
    end

    cfg = { uuid = "existing-uuid", user_name = "old", other = "kept" }
    response, response_err, saved = { data = {} }, nil, false
    local result
    Auth.importBrowserAsync({ cookies = {
        { domain = ".jd.com", name = "thor", value = "session" },
        { domain = "e.m.jd.com", name = "pin", value = "reader" },
        { domain = ".jd.com", name = "QRCodeKey", value = "temporary" },
        { domain = ".evil.jd.com", name = "pt_key", value = "wrong-domain" },
        "malformed cookie entry",
        { domain = ".jd.com", name = "bad", value = "bad;cookie" },
    } }, function(ok, err)
        result = ok
        Assert.is_nil(err)
    end)
    Assert.is_true(result)
    Assert.is_true(saved)
    Assert.eq(request.uuid, "existing-uuid")
    Assert.matches(request.cookie, "thor=session")
    Assert.matches(request.cookie, "pin=reader")
    Assert.is_false(request.cookie:find("QRCodeKey", 1, true) ~= nil)
    Assert.is_false(request.cookie:find("wrong-domain", 1, true) ~= nil)
    Assert.is_false(request.cookie:find("bad=bad", 1, true) ~= nil)
    Assert.eq(cfg.user_name, "reader")
    Assert.eq(cfg.other, "kept")

    cfg, saved = { cookie = "old-session", user_name = "old" }, false
    local previous_calls = api_calls
    Auth.importBrowserAsync({ cookies = {
        { domain = ".evil.jd.com", name = "thor", value = "wrong-domain" },
    } }, function(ok, err)
        result = ok
        Assert.not_nil(err)
    end)
    Assert.is_false(result)
    Assert.is_false(saved)
    Assert.eq(api_calls, previous_calls)

    cfg = { cookie = "old-session", user_name = "old" }
    response, response_err, saved, result = nil, "expired session", false, nil
    Auth.importBrowserAsync({ cookies = {
        { domain = ".jd.com", name = "thor", value = "new-session" },
    } }, function(ok, err)
        result = ok
        Assert.not_nil(err)
    end)
    Assert.is_false(result)
    Assert.is_false(saved)
    Assert.eq(cfg.cookie, "old-session")
end
