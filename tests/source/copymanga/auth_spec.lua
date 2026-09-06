--[[--
拷贝漫画登录密码编码用例。

@module tests.source.copymanga.auth_spec
--]]

local Assert = require("support.assert")
local Auth = require("source.copymanga.auth")
local Text = require("utils.text")

do
    -- 与站点前端一致：base64(password .. "-" .. salt)
    Assert.eq(Auth.encodePassword("secret", 123456), Text.base64Encode("secret-123456"))
    Assert.eq(Auth.encodePassword("密 码", "000001"), Text.base64Encode("密 码-000001"))
end

do
    Assert.is_false(Auth.hasSession())
    Assert.is_nil(Auth.userLabel())
    Assert.is_nil(Auth.token())
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
