--[[-- 起点账号：续期不动同步标记；换号保留记录，不询问、不查询旧账号。 @module tests.source.qidian.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch
local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local Auth = require("source.auth")
local beginLogin = Auth.beginLogin
local cfg, checks, cleared, closed = {}, 0, 0, 0
local clear_ok, delayed, late = true, false, nil
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.qidian.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        loginCheckAsync = function(cookie, cb)
            checks = checks + 1
            Assert.is_true(cookie ~= "old", "换号不能查询旧凭据")
            local function done()
                cb(cookie ~= "bad", cookie == "bad" and "expired" or nil,
                    { id = cookie == "same" and "111" or "222" })
            end
            if delayed then late = done else done() end
            return { cancel = function() end }
        end,
    }
end
package.loaded["source.auth"] = nil
package.preload["source.auth"] = function()
    return { beginLogin = beginLogin, changeAccount = Auth.changeAccount,
        ok = function() end, expired = function() return false end }
end
package.preload["source.registry"] = function()
    return { reload = function() end, invalidate = function() end,
        resolve = function() return { capabilities = function() return { shelf_add = true } end } end }
end
package.preload["book.books_db"] = function()
    return { prepareAccountSync = function(id, shelf_add)
        Assert.eq(id, "qidian", "只准备当前源")
        Assert.is_true(shelf_add)
        Assert.not_nil(cfg.cookie, "成功准备同步之后才替换凭据")
        cleared = cleared + 1
        return clear_ok
    end }
end
package.preload["reader.session"] = function()
    return { current = function() return {
        identity = { source_id = "qidian" }, ui = { onClose = function() closed = closed + 1 end },
    } end }
end
local CookieLogin = require("source.cookie_login")
CookieLogin.fromPayload = function(payload) return payload.cookie end
local Setting = require("source.qidian.setting")
local function apply(cookie)
    local ok, err
    local job = Setting.browser.apply({ cookie = cookie }, function(value, reason) ok, err = value, reason end)
    return ok, err, job
end

cfg = { cookie = "old", account_id = "111" }
Assert.is_true(apply("same"))
Assert.eq(cleared, 0, "同账号续期保留本地")
cfg = { cookie = "old", account_id = "111" }
Assert.is_true(apply("new"))
Assert.eq(cfg.cookie, "new")
Assert.eq(cfg.account_id, "222")
Assert.eq(cleared, 1)
Assert.eq(closed, 1)
Assert.is_nil(Theme.last("confirm"), "换号不弹确认")
cfg = { cookie = "old" }
local before = checks
Assert.is_true(apply("same"))
Assert.eq(checks, before + 1, "旧配置缺身份时不多查一次")
Assert.eq(cleared, 2)
cfg = { cookie = "new", account_id = "111" }
Assert.is_true(apply("new"))
Assert.eq(cleared, 3, "账号身份变了，即使 Cookie 字符串相同也准备同步")
cfg, clear_ok = { cookie = "old", account_id = "111" }, false
local ok, err = apply("new")
Assert.is_false(ok)
Assert.eq(err, "准备本地同步失败")
Assert.eq(cfg.cookie, "old", "准备失败仍保留旧凭据")
clear_ok = true
cfg = { cookie = "old", account_id = "111" }
ok, err = apply("bad")
Assert.is_false(ok)
Assert.eq(err, "expired")
Assert.eq(cfg.cookie, "old", "无效新凭据不清旧账号")
delayed = true
local called = false
local job = Setting.browser.apply({ cookie = "same" }, function() called = true end)
job.cancel()
late()
Assert.is_false(called, "取消后的校验回包不提交")
Assert.eq(cfg.cookie, "old")
