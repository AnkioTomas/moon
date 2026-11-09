--[[-- QQ阅读：新账号直接替换，不查旧登录、不弹换号确认。 @module tests.source.qqreader.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch
local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, prepared = {}, 0
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.qqreader.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        loginCheckAsync = function(cookie, cb)
            Assert.is_true(cookie ~= "old")
            cb(true, nil, { id = cookie == "same" and "111" or "222" })
            return { cancel = function() end }
        end,
    }
end
package.preload["source.registry"] = function()
    return { reload = function() end, invalidate = function() end,
        resolve = function() return { capabilities = function() return { shelf_add = true } end } end }
end
package.preload["reader.session"] = function() return { current = function() return nil end } end
package.preload["book.books_db"] = function()
    return { prepareAccountSync = function(id, shelf_add)
        Assert.eq(id, "qqreader")
        Assert.is_true(shelf_add)
        Assert.eq(cfg.cookie, "old")
        prepared = prepared + 1
        return true
    end }
end
require("source.cookie_login").fromPayload = function(payload) return payload.cookie end
local Setting = require("source.qqreader.setting")
local function apply(cookie)
    local ok
    Setting.browser.apply({ cookie = cookie }, function(result) ok = result end)
    Assert.is_true(ok)
end
cfg = { cookie = "old", account_id = "111" }
apply("same")
Assert.eq(prepared, 0)
cfg = { cookie = "old", account_id = "111" }
apply("new")
Assert.eq(prepared, 1)
Assert.eq(cfg.account_id, "222")
Assert.is_nil(Theme.last("confirm"))
cfg = { cookie = "old" }
apply("same")
Assert.eq(prepared, 2)
