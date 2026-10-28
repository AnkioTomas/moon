--[[--
source.cookie_login：Cookie 文本 / 扩展 payload 规范化、校验保存、退出清配置。

@module tests.source.cookie_login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local CookieLogin = require("source.cookie_login")

-- parse：丢格式不对的项、按名排序、接受 devtools 复制带的 `Cookie:` 前缀与换行
Assert.eq(CookieLogin.parse("b=2; a=1;bad name=3; c="), "a=1; b=2")
Assert.eq(CookieLogin.parse("Cookie: PHPSESSID=x; _c_n_=y\n"), "PHPSESSID=x; _c_n_=y")
Assert.eq(CookieLogin.parse("  "), "")
Assert.eq(CookieLogin.parse("乱七八糟"), "")
Assert.eq(CookieLogin.parse("__Host-sid=1; a.b=2; c|d=3"), "__Host-sid=1; a.b=2; c|d=3", "RFC 6265 token 字符都算合法名")

-- fromPayload：只收本域及子域，去掉前导点，域名不区分大小写
local payload = { cookies = {
    { domain = ".qidian.com", name = "ywkey", value = "k" },
    { domain = "M.Qidian.com", name = "_csrfToken", value = "t" },
    { domain = "notqidian.com", name = "x", value = "9" },
    { domain = "qidian.com.evil.net", name = "y", value = "9" },
    { domain = "m.qidian.com", name = "bad", value = "v;w" },
    "junk",
} }
Assert.eq(CookieLogin.fromPayload(payload, "qidian.com"), "_csrfToken=t; ywkey=k")
Assert.eq(CookieLogin.fromPayload({}, "qidian.com"), "")
Assert.eq(CookieLogin.fromPayload(payload, "qq.com"), "")

-- save：空串不打接口；校验失败不写配置；通过才写配置 + auth.ok + 重载源；store 可自定义
do
    local reloads, oks, checks = 0, {}, {}
    package.loaded["source.registry"] = { reload = function() reloads = reloads + 1 end }
    package.loaded["source.auth"] = { ok = function(id) oks[#oks + 1] = id end, expired = function() return false end }
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("cookietest")
    cfg.cookie, cfg.protocol = nil, nil
    Settings.saveSource("cookietest", cfg)
    local check_ok, check_err = true, nil
    local spec = {
        id = "cookietest", title = "T", cookie_title = "T", cookie_hint = "", logout_text = "",
        loggedIn = function() return Settings.getSource("cookietest").cookie ~= nil end,
        checkAsync = function(cookie, cb) checks[#checks + 1] = cookie; cb(check_ok, check_err) end,
    }
    local ok, err
    CookieLogin.save(spec, "", function(v, e) ok, err = v, e end)
    Assert.is_false(ok)
    Assert.eq(err, "没有读到 Cookie")
    Assert.len(checks, 0)

    check_ok, check_err = false, "403"
    CookieLogin.save(spec, "a=1", function(v, e) ok, err = v, e end)
    Assert.is_false(ok)
    Assert.eq(err, "403")
    Assert.is_nil(Settings.getSource("cookietest").cookie)
    Assert.eq(reloads, 0)

    check_ok, check_err = true, nil
    CookieLogin.save(spec, "a=1", function(v, e) ok, err = v, e end)
    Assert.is_true(ok)
    Assert.eq(Settings.getSource("cookietest").cookie, "a=1")
    Assert.eq(oks[1], "cookietest")
    Assert.eq(reloads, 1)
    Assert.is_true(CookieLogin.authorized(spec))

    spec.store = function(c, cookie) c.cookie, c.protocol = cookie, "web" end
    CookieLogin.save(spec, "b=2", function(v) ok = v end)
    Assert.eq(Settings.getSource("cookietest").protocol, "web")
    Assert.eq(Settings.getSource("cookietest").cookie, "b=2")

    -- 退出：确认后清配置（默认只清 cookie，clear 可自定义）并重载
    local Themed = require("support.theme_stubs")
    Themed.install()
    package.loaded["ui.themes.widgets.row"] = { widget = function(o) return o end }
    CookieLogin.logoutRow(spec)(300).callback()
    Themed.last("confirm").ok_callback()
    Assert.is_nil(Settings.getSource("cookietest").cookie)
    Assert.eq(Settings.getSource("cookietest").protocol, "web", "默认只清 cookie")
    Assert.eq(reloads, 3, "两次保存 + 一次退出都重载源")
    spec.clear = function(c) c.cookie, c.protocol = nil, nil end
    Settings.getSource("cookietest").cookie = "c=3"
    CookieLogin.logoutRow(spec)(300).callback()
    Themed.last("confirm").ok_callback()
    Assert.is_nil(Settings.getSource("cookietest").protocol)
    Assert.eq(Themed.last("toast").text, "已退出登录")
    package.loaded["ui.themes.widgets.row"] = nil

    cfg = Settings.getSource("cookietest")
    cfg.cookie, cfg.protocol = nil, nil
    Settings.saveSource("cookietest", cfg)
    package.loaded["source.registry"], package.loaded["source.auth"] = nil, nil
end

return true
