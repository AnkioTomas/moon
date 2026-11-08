--[[--
两种设备登录和电脑端 Cookie 入口；离线不留等待窗，密码不修剪。

@module tests.source.netease.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local cfg, reloads, connected = {}, 0, true
package.loaded["utils.settings"] = {
    getSource = function() return cfg end, saveSource = function() end,
}
package.loaded["source.registry"] = { reload = function() reloads = reloads + 1 end }
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }
local valid_cookie = true
package.loaded["source.netease.client"] = {
    loggedIn = function() return cfg.logged_in == true end,
    loginCheckAsync = function(cookie, cb)
        Assert.eq(cookie, "NTES=browser")
        cb(valid_cookie, not valid_cookie and "expired" or nil)
    end,
}
local passwords, cancelled, qr_started = {}, 0, 0
package.loaded["source.netease.auth"] = {
    new = function()
        return {
            cancel = function() cancelled = cancelled + 1 end,
            passwordAsync = function(_self, phone, password, code, cb)
                passwords[#passwords + 1] = { phone = phone, password = password, code = code, cb = cb }
            end,
        }
    end,
}
package.loaded["source.netease.qrlogin"] = {
    new = function(_self, cb)
        return { start = function() qr_started = qr_started + 1; cb() end }
    end,
}
local verification_callback
package.loaded["source.netease.verify"] = {
    new = function(_session, cb)
        verification_callback = cb
        return { cancel = function() end }
    end,
}
local Setting = require("source.netease.setting")
Setting.login()
local input = Themed.last("input")
Assert.len(input.fields, 2, "不再混用手机版短信协议")
input.callback("invalid", "secret")
Assert.len(passwords, 0)
input.callback("13800138000", "")
Assert.len(passwords, 0)
connected = false
input.callback("13800138000", "secret")
Assert.len(passwords, 0)
Assert.is_nil(Themed.last("progress_dialog"), "离线立即结束，不能等永不触发的联网回调")
connected = true
input.callback(" 13800138000 ", " secret ")
Assert.eq(passwords[1].phone, "13800138000")
Assert.eq(passwords[1].password, " secret ")
input.callback("13800138000", "duplicate")
Assert.len(passwords, 1, "重复点击不能覆盖在途请求")
passwords[1].cb(nil, "验证码错误", true)
verification_callback("ab12")
Assert.eq(passwords[2].code, "ab12")
passwords[2].cb(true)
Assert.is_true(input.closed)
Assert.eq(reloads, 1)
Assert.eq(cancelled, 1)

Setting.login()
input = Themed.last("input")
input.callback("13800138000", "secret")
Themed.last("progress_dialog").on_cancel()
Assert.is_true(Themed.last("progress_dialog").closed)
input.callback("13800138000", "retry")
Assert.len(passwords, 4)
input:close()
Assert.eq(cancelled, 3)
local rows = Setting.rows()
rows[2](400).callback()
Assert.eq(qr_started, 1)
local opened
package.loaded["utils.extension"] = {
    call = function(name, path, title)
        opened = { name = name, path = path, title = title }
        return { close = function() end }
    end,
}
Assert.eq(rows[3](400).title, "浏览器登录")
rows[3](400).callback()
Assert.eq(opened.path, "/cookie.html")
package.loaded["utils.extension"] = nil
rows[4](400).callback()
Assert.eq(Themed.last("input").title, "网易云阅读登录 Cookie")
Assert.eq(Setting.browser.domain, "yuedu.163.com")
Assert.eq(Setting.browser.check, "https://yuedu.163.com/myinfor.do")
local accepted
Setting.browser.apply({ cookies = {
    { domain = ".yuedu.163.com", name = "NTES", value = "browser" },
    { domain = ".weibo.com", name = "OTHER", value = "excluded" },
} }, function(ok) accepted = ok end)
Assert.is_true(accepted)
Assert.eq(cfg.cookie, "NTES=browser")
Assert.is_nil(cfg.csrf)
Assert.is_true(Setting.browser.isAuthorized())
valid_cookie = false
Setting.browser.apply({ cookies = {
    { domain = ".yuedu.163.com", name = "NTES", value = "browser" },
} }, function(ok) accepted = ok end)
Assert.is_false(accepted)
Assert.eq(cfg.cookie, "NTES=browser")
