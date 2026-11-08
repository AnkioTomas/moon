--[[-- 长佩账号切换不询问，数字 uid 规范化后判断同账号续期。 @module tests.source.changpei.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch
local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, cleared = {}, 0
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.changpei.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        userAsync = function(cookie, cb)
            Assert.is_true(cookie ~= "session=old", "不查询旧账号")
            cb({ uid = cookie == "session=same" and 111 or 222 })
            return { cancel = function() end }
        end,
    }
end
package.preload["source.registry"] = function() return { reload = function() end, invalidate = function() end } end
package.preload["reader.session"] = function() return { current = function() return nil end } end
package.preload["book.store"] = function()
    return { forgetSource = function(id)
        Assert.eq(id, "changpei")
        Assert.is_nil(cfg.cookie)
        cleared = cleared + 1
        return true
    end }
end
local Setting = require("source.changpei.setting")
local function apply(value)
    local ok
    Setting.browser.apply({ cookies = { { name = "session", value = value, domain = ".gongzicp.com" } } },
        function(result) ok = result end)
    Assert.is_true(ok)
end
cfg = { cookie = "session=old", account_id = "111" }
apply("same")
Assert.eq(cleared, 0)
cfg = { cookie = "session=old", account_id = "111" }
apply("new")
Assert.eq(cleared, 1)
Assert.eq(cfg.account_id, "222")
Assert.is_nil(Theme.last("confirm"))
cfg = { cookie = "session=old" }
apply("same")
Assert.eq(cleared, 2)
Assert.eq(cfg.account_id, "111")
