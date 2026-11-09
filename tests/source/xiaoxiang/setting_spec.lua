--[[-- 潇湘账号：续期不动同步状态，换号保留本地记录。 @module tests.source.xiaoxiang.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch
local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, prepared = {}, 0
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.xiaoxiang.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        userAsync = function(cookie, cb)
            Assert.is_true(cookie ~= "session=old")
            cb({ id = cookie == "session=same" and "111" or "222" })
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
        Assert.eq(id, "xiaoxiang")
        Assert.is_true(shelf_add)
        Assert.eq(cfg.cookie, "session=old")
        prepared = prepared + 1
        return true
    end }
end
local Setting = require("source.xiaoxiang.setting")
local function apply(value)
    local ok
    Setting.browser.apply({ cookies = { { name = "session", value = value, domain = ".xxsypro.com" } } },
        function(result) ok = result end)
    Assert.is_true(ok)
end
cfg = { cookie = "session=old", account_id = "111" }
apply("same")
Assert.eq(prepared, 0)
cfg = { cookie = "session=old", account_id = "111" }
apply("new")
Assert.eq(prepared, 1)
Assert.eq(cfg.account_id, "222")
Assert.is_nil(Theme.last("confirm"))
cfg = { cookie = "session=old" }
apply("same")
Assert.eq(prepared, 2)
