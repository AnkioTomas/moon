--[[-- QQ阅读同账号续期、旧配置迁移、换号确认和取消。 @module tests.source.qqreader.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, cleared, closed, old_ok, delayed, late = {}, 0, 0, true, false, nil
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.qqreader.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        loginCheckAsync = function(cookie, cb)
            local function done()
                if cookie == "old" then cb(old_ok, old_ok and nil or "offline", { id = "111" })
                else cb(true, nil, { id = cookie == "same" and "111" or "222" }) end
            end
            if cookie == "old" and delayed then late = done else done() end
            return { cancel = function() end }
        end,
    }
end
package.preload["source.registry"] = function() return { reload = function() end, invalidate = function() end } end
package.preload["source.auth"] = function() return { ok = function() end, expired = function() return false end } end
package.preload["source.logout"] = function() return { abort = function() end } end
package.preload["book.store"] = function()
    return { forgetSource = function()
        Assert.is_nil(cfg.cookie)
        cleared = cleared + 1
        return true
    end }
end
package.preload["reader.session"] = function()
    return { current = function() return {
        identity = { source_id = "qqreader" }, ui = { onClose = function() closed = closed + 1 end },
    } end }
end
local Setting = require("source.qqreader.setting")
local CookieLogin = require("source.cookie_login")
local from_payload = CookieLogin.fromPayload
CookieLogin.fromPayload = function(payload) return payload.cookie end

do
    cfg = { cookie = "old", account_id = "111" }
    local ok
    Setting.browser.apply({ cookie = "same" }, function(value) ok = value end)
    Assert.is_true(ok)
    Assert.eq(cfg.cookie, "same")
    Assert.eq(cleared, 0)
end

do
    cfg = { cookie = "old" }
    local ok
    Setting.browser.apply({ cookie = "same" }, function(value) ok = value end)
    Assert.is_true(ok)
    Assert.eq(cfg.account_id, "111")
    Assert.eq(cleared, 0)
end

do
    cfg = { cookie = "old", account_id = "111" }
    local ok
    Setting.browser.apply({ cookie = "new" }, function(value) ok = value end)
    Assert.is_nil(ok)
    Assert.eq(cfg.cookie, "old")
    Theme.last("confirm").cancel_callback()
    Assert.is_false(ok)
    Assert.eq(cleared, 0)
    Setting.browser.apply({ cookie = "new" }, function(value) ok = value end)
    Theme.last("confirm").ok_callback()
    Assert.is_true(ok)
    Assert.eq(cfg.cookie, "new")
    Assert.eq(cfg.account_id, "222")
    Assert.eq(closed, 1)
    Assert.eq(cleared, 1)
end

do
    cfg, old_ok = { cookie = "old" }, false
    local ok, err
    Setting.browser.apply({ cookie = "same" }, function(value, reason) ok, err = value, reason end)
    Assert.is_false(ok)
    Assert.matches(err, "无法确认旧账号")
    Assert.eq(cfg.cookie, "old")
end

do
    cfg, old_ok, delayed = { cookie = "old" }, true, true
    local called = false
    local job = Setting.browser.apply({ cookie = "same" }, function() called = true end)
    job.cancel()
    late()
    Assert.is_false(called)
    Assert.eq(cfg.cookie, "old")
end

CookieLogin.fromPayload = from_payload
