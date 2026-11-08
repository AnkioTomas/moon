--[[--
晋江登录：不静默覆盖旧账号、取消迟到回包、离线立即失败。

@module tests.source.jjwxc.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local cfg, online, pending, cancelled, stored = {}, true, nil, false, 0
local cookie_pending, cookie_cancelled, cookie_async
package.loaded["utils.settings"] = { getSource = function() return cfg end, saveSource = function() end }
package.loaded["source.registry"] = { reload = function() end }
package.loaded["source.auth"] = { ok = function() end }
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
local App = {
    loginAsync = function(_account, password, _verify, cb)
        Assert.eq(password, " password ", "密码按原值提交")
        pending = cb
        return { cancel = function() cancelled = true end }
    end,
    save = function(_account, _password, token) stored = stored + 1; cfg.token = token end,
}
package.loaded["source.jjwxc.protocols.app"] = App
package.loaded["source.jjwxc.protocols"] = { current = function() end, select = function() end }
package.loaded["source.jjwxc.protocols.web"] = {
    favAsync = function(_cookie, cb)
        if cookie_async then cookie_pending = cb else cb({}) end
        return { cancel = function() cookie_cancelled = true end }
    end,
}
package.loaded["source.jjwxc.setting"] = nil
local Setting = require("source.jjwxc.setting")

Setting.login()
Themed.last("input").callback("test", " password ")
Themed.last("progress_dialog").on_cancel()
Assert.is_true(cancelled)
pending("late")
Assert.eq(stored, 0)

Setting.login()
Themed.last("input").callback("test", " password ")
cfg.token = "newer"
pending("older")
Assert.eq(stored, 0)
Assert.eq(cfg.token, "newer")
Assert.eq(Themed.last("toast").text, "账号已变化，请重新登录")

local result, reason
cfg.cookie = "sid=old"
Setting.browser.apply({ cookies = { { domain = ".jjwxc.com", name = "sid", value = "new" } } },
    function(ok, err) result, reason = ok, err end)
Assert.is_false(result)
Assert.eq(reason, "无法确认旧账号，请先退出旧账号再登录")
Assert.eq(cfg.cookie, "sid=old")
cfg.token = nil
Setting.browser.apply({ cookies = { { domain = ".jjwxc.com", name = "sid", value = "old" } } },
    function(ok) result = ok end)
Assert.is_true(result, "同一 Cookie 重新校验不清库")

cfg, cookie_async, result = {}, true, nil
local cookie_job = Setting.browser.apply({ cookies = { { domain = ".jjwxc.com", name = "sid", value = "new" } } },
    function(ok) result = ok end)
cookie_job.cancel()
Assert.is_true(cookie_cancelled, "关闭登录必须取消校验请求")
cookie_pending({})
Assert.is_nil(cfg.cookie)
Assert.is_nil(result)

cfg, online, pending = {}, false, nil
Setting.login()
Themed.last("input").callback("test", " password ")
Assert.is_nil(pending)
Assert.eq(Themed.last("toast").text, "未联网")
