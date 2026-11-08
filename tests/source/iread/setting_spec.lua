--[[--
iRead 候选登录的取消与竞态、Cookie 域范围及手动粘贴入口。

@module tests.source.iread.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }
local cfg, saved, reloaded = { token = "old-token" }, 0, 0
local cleared = 0
package.loaded["source.logout"] = { row = require("source.logout").row, clear = function(_id, clear)
    clear(); cleared = cleared + 1; return true
end }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saved = saved + 1 end,
}
package.loaded["source.registry"] = { reload = function() reloaded = reloaded + 1 end }
local requests = {}
package.loaded["source.iread.client"] = {
    credential = function()
        if cfg.token then return { token = cfg.token } end
        if cfg.cookie then return { cookie = cfg.cookie } end
    end,
    userAsync = function(cred, cb)
        local request = { cred = cred, cb = cb }
        requests[#requests + 1] = request
        return { cancel = function() request.cancelled = true end }
    end,
}
local Setting = require("source.iread.setting")
local calls, result, reason = 0, nil, nil
local function done(user, err) calls, result, reason = calls + 1, user, err end

local handle = Setting.save({ token = "candidate" }, done)
handle:cancel()
Assert.is_true(requests[1].cancelled)
requests[1].cb({ nickname = "测试" })
Assert.eq(calls, 0)
Assert.eq(cfg.token, "old-token")
Assert.eq(saved, 0)

Setting.save({ token = "candidate" }, done)
requests[2].cb(nil, "network failed")
Assert.eq(cfg.token, "old-token")
Assert.eq(reason, "network failed")
Assert.eq(saved, 0)

Setting.save({ token = "candidate" }, done)
cfg.token = "new-token"
requests[3].cb({ nickname = "测试" })
Assert.is_nil(result)
Assert.eq(reason, "登录状态已变化，请重试")
Assert.eq(cfg.token, "new-token")
Assert.eq(saved, 0)

Setting.save({ token = "different-token" }, done)
requests[4].cb({ nickname = "测试" })
Assert.is_true(result ~= nil)
Assert.is_nil(reason)
Assert.eq(cfg.token, "different-token")
Assert.eq(cleared, 1, "凭据变化时直接清旧源")
Assert.is_nil(Themed.last("confirm"))
cfg.token = nil
saved, reloaded = 0, 0

handle = Setting.browser.apply({ cookies = {
    { domain = ".ankio.net", name = "parent", value = "ok" },
    { domain = "iread.ankio.net", name = "site", value = "ok" },
    { domain = "other.ankio.net", name = "sibling", value = "no" },
    { domain = "ankio.net.evil.test", name = "evil", value = "no" },
} }, function(ok, err) result, reason = ok, err end)
Assert.eq(requests[5].cred.cookie, "parent=ok; site=ok")
requests[5].cb({ nickname = "测试" })
Assert.is_true(result)
Assert.is_nil(reason)
Assert.is_nil(cfg.token)
Assert.eq(cfg.cookie, "parent=ok; site=ok")
Assert.eq(saved, 1)
Assert.eq(reloaded, 1)

local rows = Setting.rows()
Assert.eq(rows[2](500).title, "浏览器登录")
local cookie_row = rows[3](500)
Assert.eq(cookie_row.title, "粘贴 Cookie")
cookie_row.callback()
local input = Themed.last("input")
Assert.eq(input.title, "iRead 登录 Cookie")
input.callback("Cookie: sid=manual")
Assert.eq(requests[6].cred.cookie, "sid=manual")
Themed.last("progress_dialog").on_cancel()
Assert.is_true(requests[6].cancelled)
