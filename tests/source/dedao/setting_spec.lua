--[[--
短信安全验证接回原登录输入窗，保留候选会话并取消真正的在飞步骤。

@module tests.source.dedao.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch
local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local Input = require("ui.themes.widgets.input")
local make_input = Input.new
function Input:new(opts)
    local window = make_input(self, opts)
    local show = window.show
    window.show = function(self) show(self) end
    return window
end
local sent, verified, sms_session, sms_code
local login_ok, defer_login, login_callback
local request_cancelled, verification_cancelled
local candidate = { phone = "13800000000", oauth = "test-token", jar = {} }
local cfg, saves, reloads, accepted = {}, 0, 0, 0
package.preload["utils.settings"] = function()
    return {
        getSource = function(_id) return cfg end,
        saveSource = function(_id) saves = saves + 1 end,
    }
end
package.preload["source.registry"] = function() return { reload = function() reloads = reloads + 1 end } end
package.preload["source.auth"] = function() return { ok = function(_id) accepted = accepted + 1 end } end
package.preload["ui/network/manager"] = function()
    return { runWhenConnected = function(_network, cb) cb() end }
end
package.preload["source.dedao.client"] = function()
    return {
        sendCodeAsync = function(_phone, cb)
            sent = cb
            cb(nil, nil, { session = candidate, captcha_id = "test-id" })
            return { cancel = function() request_cancelled = true end }
        end,
        smsLoginAsync = function(session, code, cb)
            sms_session, sms_code = session, code
            login_callback = cb
            if not defer_login then cb(login_ok, not login_ok and "test-login-error" or nil) end
            return { cancel = function() request_cancelled = true end }
        end,
    }
end
package.preload["source.dedao.verify"] = function()
    return { new = function(challenge, cb)
        Assert.eq(challenge.session, candidate)
        verified = cb
        return { cancel = function() verification_cancelled = true end }
    end }
end
local Setting = require("source.dedao.setting")
local function open()
    Setting.open()
    Theme.choose(Theme.last("sheet"), 1)
    local input = Theme.last("input")
    input.actions[1].callback("13800000000")
    Theme.last("confirm").ok_callback()
    return input
end
local input = open()
Assert.is_true(Theme.last("progress_dialog").closed)
Assert.is_nil(Theme.last("toast"), "要求滑块时不能弹短信已发送")
Assert.is_true(not input.closed)
input:close()
Assert.is_true(verification_cancelled, "同步短信回调不能把网页取消句柄覆盖成旧请求")
Assert.is_nil(request_cancelled)
verified(candidate)
Assert.is_nil(Theme.last("toast"), "关输入窗后不显示迟到成功")

input = open()
verified(candidate)
Assert.eq(Theme.last("toast").text, "短信已发送，请在设备上填写验证码")
Assert.is_true(input.validate("13800000000", "123456"))
Assert.is_true(not input.validate("13900000000", "123456"))
input.callback("13800000000", "123456")
Assert.eq(sms_session, candidate)
Assert.eq(sms_code, "123456")
Assert.eq(Theme.last("toast").text, "test-login-error")
input:close()
Assert.is_nil(request_cancelled, "同步完成登录不留下旧取消句柄")

login_ok = true
input = open()
verified(candidate)
input.callback("13800000000", "123456")
Assert.is_true(input.closed, "show 不返回窗口时，成功登录仍能关闭真正的输入窗")
Assert.is_true(cfg.logged_in)
Assert.eq(saves, 1)
Assert.eq(reloads, 1)
Assert.eq(accepted, 1)
Assert.eq(Theme.last("toast").text, "登录成功")

defer_login = true
input = open()
verified(candidate)
input.callback("13800000000", "123456")
Assert.is_true(not input.closed)
login_callback(true)
Assert.is_true(input.closed, "HTTP 异步成功也关闭原输入窗")
Assert.eq(saves, 2)
Assert.eq(reloads, 2)
Assert.eq(Theme.last("toast").text, "登录成功")

-- Cookie / 浏览器登录行与校验保存
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }
local cookie_calls = {}
package.preload["source.dedao.client"] = function()
    return {
        loggedIn = function() return cfg.logged_in == true and cfg.cookie ~= nil end,
        reset = function() end,
        confirmLoginAsync = function(jar, cb)
            cookie_calls[#cookie_calls + 1] = jar
            cb(true)
            return { cancel = function() end }
        end,
        sendCodeAsync = function(_phone, cb)
            sent = cb
            cb(nil, nil, { session = candidate, captcha_id = "test-id" })
            return { cancel = function() request_cancelled = true end }
        end,
        smsLoginAsync = function(session, code, cb)
            sms_session, sms_code = session, code
            login_callback = cb
            if not defer_login then cb(login_ok, not login_ok and "test-login-error" or nil) end
            return { cancel = function() request_cancelled = true end }
        end,
    }
end
package.loaded["source.dedao.client"] = nil
package.loaded["source.dedao.setting"] = nil
package.loaded["source.cookie_login"] = nil
Setting = require("source.dedao.setting")
Assert.is_true(type(Setting.browser) == "table")
Assert.eq(Setting.browser.domain, "www.dedao.cn")
Assert.is_true(type(Setting.browser.icon) == "string" and Setting.browser.icon:match("^https://"))
cfg = {}
local rows = Setting.rows()
Assert.eq(rows[2](400).title, "浏览器登录")
Assert.eq(rows[3](400).title, "粘贴 Cookie")
rows[3](400).callback()
local paste = Theme.last("input")
Assert.eq(paste.title, "得到登录 Cookie")
paste.callback("csrfToken=abc; token=xyz")
Assert.eq(cookie_calls[1].csrfToken, "abc")
Assert.eq(cookie_calls[1].token, "xyz")
Assert.eq(cfg.cookie, "csrfToken=abc; token=xyz")
Assert.is_true(cfg.logged_in)
