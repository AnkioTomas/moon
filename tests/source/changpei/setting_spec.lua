--[[-- 长佩登录账号边界、旧配置迁移与取消。 @module tests.source.changpei.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, cleared, closed, old_ok, delayed, late = {}, 0, 0, true, false, nil
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.changpei.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        userAsync = function(cookie, cb)
            local function done()
                if cookie == "session=old" then cb(old_ok and { uid = 111 } or nil, old_ok and nil or "offline")
                else cb({ uid = cookie == "session=same" and 111 or 222 }) end
            end
            if cookie == "session=old" and delayed then late = done else done() end
            return { cancel = function() end }
        end,
    }
end
package.preload["source.registry"] = function() return { reload = function() end, invalidate = function() end } end
package.preload["source.auth"] = function() return { ok = function() end, expired = function() return false end } end
package.preload["source.logout"] = function() return { abort = function() end } end
package.preload["book.store"] = function()
    return { forgetSource = function()
        Assert.is_nil(cfg.cookie, "清本地前停用凭证，不能把清库当远端删书")
        cleared = cleared + 1
        return true
    end }
end
package.preload["reader.session"] = function()
    return { current = function() return {
        identity = { source_id = "changpei" }, ui = { onClose = function() closed = closed + 1 end },
    } end }
end
local Setting = require("source.changpei.setting")
local function payload(value)
    return { cookies = { { name = "session", value = value, domain = ".gongzicp.com" } } }
end

cfg = { cookie = "session=old", account_id = "111" }
local ok
Setting.browser.apply(payload("same"), function(value) ok = value end)
Assert.is_true(ok)
Assert.eq(cfg.cookie, "session=same")
Assert.eq(cleared, 0)

cfg = { cookie = "session=old" }
Setting.browser.apply(payload("same"), function(value) ok = value end)
Assert.is_true(ok)
Assert.eq(cfg.account_id, "111")
Assert.eq(cleared, 0)

cfg, ok = { cookie = "session=old", account_id = "111" }, nil
Setting.browser.apply(payload("new"), function(value) ok = value end)
Assert.is_nil(ok)
Assert.eq(cfg.cookie, "session=old")
Theme.last("confirm").cancel_callback()
Assert.is_false(ok)
Assert.eq(cleared, 0)
Setting.browser.apply(payload("new"), function(value) ok = value end)
Theme.last("confirm").ok_callback()
Assert.is_true(ok)
Assert.eq(cfg.account_id, "222")
Assert.eq(closed, 1)
Assert.eq(cleared, 1)

cfg, old_ok = { cookie = "session=old" }, false
local err
Setting.browser.apply(payload("same"), function(value, reason) ok, err = value, reason end)
Assert.is_false(ok)
Assert.matches(err, "无法确认旧账号")
Assert.eq(cfg.cookie, "session=old")

cfg, old_ok, delayed = { cookie = "session=old" }, true, true
local called = false
local job = Setting.browser.apply(payload("same"), function() called = true end)
job.cancel()
late()
Assert.is_false(called)
Assert.eq(cfg.cookie, "session=old")

cfg, delayed = { cookie = "session=old", account_id = "111" }, false
Setting.browser.apply(payload("new"), function(value, reason) ok, err = value, reason end)
cfg.cookie = "session=another"
Theme.last("confirm").ok_callback()
Assert.is_false(ok)
Assert.matches(err, "账号已变化")
Assert.eq(cfg.cookie, "session=another")
