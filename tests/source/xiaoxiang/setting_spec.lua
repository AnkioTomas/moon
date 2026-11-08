--[[--
潇湘同账号续期、旧配置迁移与换号确认。

@module tests.source.xiaoxiang.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local A = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, cleared, closed, delayed, late, old_ok = {}, 0, 0, false, nil, true
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.xiaoxiang.client"] = function()
    return { cookie = function() return cfg.cookie end, userAsync = function(cookie, cb)
        local function done()
            if cookie == "session=old" then cb(old_ok and { id = "111" } or nil, old_ok and nil or "timeout")
            else cb({ id = cookie == "session=same" and "111" or "222" }) end
        end
        if delayed then late = done else done() end
        return { cancel = function() end }
    end }
end
package.preload["source.registry"] = function() return { reload = function() end, invalidate = function() end } end
package.preload["source.auth"] = function() return { ok = function() end, expired = function() return false end } end
package.preload["source.logout"] = function() return { abort = function() end } end
package.preload["book.store"] = function()
    return { forgetSource = function()
        A.is_nil(cfg.cookie, "清库时必须停用账号，不能推旧墓碑")
        cleared = cleared + 1
        return true
    end }
end
package.preload["reader.session"] = function()
    return { current = function() return {
        identity = { source_id = "xiaoxiang" }, ui = { onClose = function() closed = closed + 1 end },
    } end }
end
local S = require("source.xiaoxiang.setting")
local function payload(value)
    return { cookies = { { name = "session", value = value, domain = ".xxsypro.com" } } }
end
local ok, err
cfg = { cookie = "session=old", account_id = "111" }
S.browser.apply(payload("same"), function(value) ok = value end)
A.is_true(ok)
A.eq(cleared, 0)
cfg = { cookie = "session=old" }
S.browser.apply(payload("same"), function(value) ok = value end)
A.is_true(ok)
A.eq(cfg.account_id, "111")
cfg, ok = { cookie = "session=old", account_id = "111" }, nil
S.browser.apply(payload("new"), function(value) ok = value end)
A.is_nil(ok)
Theme.last("confirm").cancel_callback()
A.is_false(ok)
A.eq(cfg.cookie, "session=old")
S.browser.apply(payload("new"), function(value) ok = value end)
Theme.last("confirm").ok_callback()
A.is_true(ok)
A.eq(cfg.account_id, "222")
A.eq(cleared, 1)
A.eq(closed, 1)
cfg, old_ok = { cookie = "session=old" }, false
S.browser.apply(payload("same"), function(value, reason) ok, err = value, reason end)
A.is_false(ok)
A.matches(err, "无法确认旧账号")
A.eq(cfg.cookie, "session=old")
cfg, delayed = { cookie = "session=old" }, true
local called = false
local handle = S.browser.apply(payload("same"), function() called = true end)
handle.cancel()
late()
A.is_false(called)
A.eq(cfg.cookie, "session=old")
