--[[--
拷贝漫画登录密码编码用例。

@module tests.source.copymanga.auth_spec
--]]

local Assert = require("support.assert")
package.loaded["json"] = require("support.json_stub")
local Auth = require("source.copymanga.auth")
local Text = require("utils.text")

do
    -- 与站点前端一致：base64(password .. "-" .. salt)
    Assert.eq(Auth.encodePassword("secret", 123456), Text.base64Encode("secret-123456"))
    Assert.eq(Auth.encodePassword("密 码", "000001"), Text.base64Encode("密 码-000001"))
end

do
    local settings = require("utils.settings")
    local current = settings.getSource("copymanga")
    local original_base = current.base_url
    current.base_url = "https://www.copy4000.com"
    settings.saveSource("copymanga", current)
    local pending, request
    local cancelled = false
    package.loaded["http.request"] = {
        request = function(opts, cb)
            request, pending = opts, cb
            return { cancel = function() cancelled = true end }
        end,
    }
    Auth.clearSession()
    local ok, err
    local job = Auth.loginAsync("user", " spaced password ", function(result, e) ok, err = result, e end)
    Assert.eq(request.url, "https://api.copy4000.com/api/v3/login")
    Assert.is_false(request.allow_redirects)
    Assert.eq(request.cache_ttl, 0)
    Assert.is_true(request.body:find(require("utils.text").urlEncode(Auth.encodePassword(" spaced password ",
        require("utils.text").urlDecode(request.body:match("salt=([^&]+)")))), 1, true) ~= nil)
    pending({ body = '{"code":200,"results":{"token":"first","user_id":"1"}}' })
    Assert.is_true(ok)
    Assert.eq(current.password, " spaced password ", "登录成功必须落盘密码，401 才能自动重登")
    Assert.eq(current.username, "user")

    job = Auth.loginAsync("other", "pass", function(result, e) ok, err = result, e end)
    pending({ body = '{"code":200,"results":{"token":"other","user_id":"2"}}' })
    Assert.is_nil(ok)
    Assert.eq(err, "请先退出当前账号")
    Assert.eq(current.token, "first")

    job = Auth.loginAsync("user", "pass", function(result, e) ok, err = result, e end)
    job.cancel()
    pending({ body = '{"code":200,"results":{"token":"cancelled","user_id":"1"}}' })
    Assert.is_true(cancelled)
    Assert.eq(current.token, "first")
    Auth.clearSession()
    current.base_url = original_base
    settings.saveSource("copymanga", current)
end

do
    Assert.is_false(Auth.hasSession())
    Assert.is_nil(Auth.userLabel())
    Assert.is_nil(Auth.credentials())
end

do
    local settings = require("utils.settings")
    local cfg = settings.getSource("copymanga")
    cfg.username = "user"
    cfg.password = "secret"
    cfg.token = "tok"
    settings.saveSource("copymanga", cfg)
    local username, password = Auth.credentials()
    Assert.eq(username, "user")
    Assert.eq(password, "secret")
    Auth.clearSession()
    Assert.is_nil(Auth.credentials())
    Assert.is_false(Auth.hasSession())
end
