--[[--
书旗 Cookie 必须经官方账号校验，失败、取消与换号不覆盖旧会话。
@module tests.source.shuqi.cookie_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["json"] = JSON
local cfg, requests = {}, {}
package.loaded["utils.settings"] = { getSource = function() return cfg end, saveSource = function() end }
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local request = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = request
        return { cancel = function() request.cancelled = true end }
    end,
}
local Mapper = require("source.shuqi.mapper")
Assert.eq(Mapper.cookieSession("shuqi_user_id=7; shuqi_token=one%2Btwo%3D").token, "one+two=")
Assert.eq(Mapper.cookieSession("shuqi_user_id=7; shuqi_token=one+two").token, "one+two")
Assert.is_nil(Mapper.cookieSession("shuqi_user_id=8000000; shuqi_token=token"))
Assert.is_nil(Mapper.cookieSession("shuqi_user_id=7; shuqi_token=bad%0D%0Atoken"))
Assert.is_nil(Mapper.cookieSession("shuqi_token=token"))
Assert.is_nil(Mapper.account({ status = 200, data = { ["7"] = { userId = 8 } } }, "7"))
local Client = require("source.shuqi.client")
local result, reason
local function answer(token)
    return JSON.encode({ status = 200, data = { ["7"] = { userId = 7, nickName = token } } })
end
local function login(token)
    return Client.loginCookieAsync("Cookie: shuqi_user_id=7; shuqi_token=" .. token
        .. "; shuqi_fingerprint=browser; unrelated=private", function(value, err) result, reason = value, err end)
end
login("first")
local request = requests[#requests]
Assert.eq(request.opts.headers.Authorization, "Bearer first")
Assert.is_nil(request.opts.headers.Cookie)
Assert.eq(request.opts.cache_ttl, 0)
Assert.is_nil(request.url:find("first", 1, true), "令牌不进入 URL")
Assert.matches(request.url, "/userBaseInfo%?")
request.cb(answer("name"))
Assert.eq(cfg.token, "first")
Assert.eq(cfg.user_id, "7")
Assert.eq(cfg.imei, "browser")
Assert.eq(cfg.name, "name")
Assert.is_true(cfg.logged_in)
Assert.is_nil(cfg.cookie, "不保存无关 Cookie")

login("bad")
requests[#requests].cb(nil, "offline")
Assert.eq(reason, "offline")
Assert.eq(cfg.token, "first")
login("bad")
requests[#requests].cb(JSON.encode({ status = 10003, message = "expired" }))
Assert.eq(reason, "expired")
Assert.eq(cfg.token, "first")
login("bad")
requests[#requests].cb("not json")
Assert.eq(reason, "登录响应无效")
Assert.eq(cfg.token, "first")
login("bad")
requests[#requests].cb(answer("wrong"):gsub('"userId":7', '"userId":8'))
Assert.is_nil(result)
Assert.eq(cfg.token, "first")

local calls = 0
local cancelled = Client.loginCookieAsync("shuqi_user_id=7; shuqi_token=cancelled", function() calls = calls + 1 end)
cancelled:cancel()
Assert.is_true(requests[#requests].cancelled)
requests[#requests].cb(answer("cancelled"))
Assert.eq(calls, 0)
Assert.eq(cfg.token, "first")
login("old")
local late = requests[#requests]
login("latest")
requests[#requests].cb(answer("latest"))
late.cb(answer("old"))
Assert.eq(cfg.token, "latest")
Assert.eq(reason, "登录状态已变化，请重试")
Client.loginCookieAsync("shuqi_user_id=8; shuqi_token=other", function(value, err) result, reason = value, err end)
requests[#requests].cb(JSON.encode({ status = 200, data = { ["8"] = { userId = 8 } } }))
Assert.is_nil(result)
Assert.matches(reason, "请先退出旧书旗账号")
Assert.eq(cfg.token, "latest")

local reloaded = 0
package.loaded["source.auth"] = { ok = function() end, expired = function() return false end }
package.loaded["source.registry"] = { reload = function() reloaded = reloaded + 1 end }
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
package.loaded["ui.themes.widgets.row"] = { widget = function(opts) return opts end }
local Setting = require("source.shuqi.setting")
Setting.browser.apply({ cookies = {
    { domain = ".shuqi.com", name = "shuqi_user_id", value = "7" },
    { domain = ".shuqi.com", name = "shuqi_token", value = "allowed" },
    { domain = "other.shuqi.com", name = "shuqi_token", value = "wrong" },
    { domain = "shuqi.com.evil.test", name = "shuqi_token", value = "wrong" },
} }, function(ok) result = ok end)
Assert.eq(requests[#requests].opts.headers.Authorization, "Bearer allowed")
requests[#requests].cb(answer("allowed"))
Assert.is_true(result)
Assert.eq(reloaded, 1)
local rows = Setting.rows()
Assert.eq(rows[3](400).title, "粘贴 Cookie")
rows[3](400).callback()
Themed.last("input").callback("shuqi_user_id=7; shuqi_token=cancel-ui")
Themed.last("progress_dialog").on_cancel()
requests[#requests].cb(answer("cancel-ui"))
Assert.eq(cfg.token, "allowed")
Assert.eq(reloaded, 1)
