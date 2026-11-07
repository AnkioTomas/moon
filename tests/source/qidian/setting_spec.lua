--[[-- 起点三种登录统一账号边界：续期、旧配置迁移、确认换号、清库失败与候选取消。 @module tests.source.qidian.setting_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local cfg, checks, cleared, aborted, closed, late = {}, {}, 0, 0, 0, nil
local clear_ok, old_ok, delay_old = true, true, false
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.qidian.client"] = function()
    return {
        cookie = function() return cfg.cookie end,
        loginCheckAsync = function(cookie, cb)
            checks[#checks + 1] = cookie
            local function done()
                if cookie == "old" then cb(old_ok, old_ok and nil or "offline", { id = "111" })
                else cb(true, nil, { id = cookie == "same" and "111" or "222" }) end
            end
            if cookie == "old" and delay_old then late = done else done() end
            return { cancel = function() aborted = aborted + 1 end }
        end,
    }
end
package.preload["source.registry"] = function() return { reload = function() end, invalidate = function() end } end
package.preload["source.auth"] = function() return { ok = function() end, expired = function() return false end } end
package.preload["source.logout"] = function() return { abort = function() aborted = aborted + 1 end } end
package.preload["book.store"] = function()
    return { forgetSource = function()
        Assert.is_nil(cfg.cookie, "清库前隔离旧凭据，不能把本地清理上行")
        cleared = cleared + 1
        return clear_ok
    end }
end
package.preload["reader.session"] = function()
    return { current = function() return {
        identity = { source_id = "qidian" }, ui = { onClose = function() closed = closed + 1 end },
    } end }
end
local Setting = require("source.qidian.setting")

do
    cfg = { cookie = "old", account_id = "111" }
    local ok
    Setting.browser.apply({ cookies = { { domain = ".qidian.com", name = "same", value = "x" } } },
        function(value) ok = value end)
    -- 直接规范化的 Cookie 是 same=x，候选测试账号是 222，所以先有换号确认。
    Assert.is_nil(ok)
    Theme.last("confirm").cancel_callback()
    Assert.is_false(ok)
    Assert.eq(cfg.cookie, "old")
    Assert.eq(cleared, 0)
end

local CookieLogin = require("source.cookie_login")
local original_parse = CookieLogin.fromPayload
CookieLogin.fromPayload = function(payload) return payload.cookie end

do
    cfg = { cookie = "old", account_id = "111" }
    local ok
    Setting.browser.apply({ cookie = "same" }, function(value) ok = value end)
    Assert.is_true(ok)
    Assert.eq(cfg.cookie, "same")
    Assert.eq(cfg.account_id, "111")
    Assert.eq(cleared, 0, "同账号续期不清书架、进度或笔记")
end

do
    cfg = { cookie = "old" }
    checks = {}
    local ok
    Setting.browser.apply({ cookie = "same" }, function(value) ok = value end)
    Assert.is_true(ok)
    Assert.len(checks, 2, "旧配置先验证原 Cookie 的稳定账号身份")
    Assert.eq(cfg.account_id, "111")
    Assert.eq(cleared, 0)
end

do
    cfg = { cookie = "old", account_id = "111" }
    local ok
    Setting.browser.apply({ cookie = "new" }, function(value) ok = value end)
    Assert.is_nil(ok)
    Assert.eq(cfg.cookie, "old", "确认前不替换登录态")
    Theme.last("confirm").ok_callback()
    Assert.is_true(ok)
    Assert.eq(cfg.cookie, "new")
    Assert.eq(cfg.account_id, "222")
    Assert.eq(cleared, 1)
    Assert.eq(closed, 1, "正常结束旧阅读会话")
end

do
    cfg, clear_ok = { cookie = "old", account_id = "111" }, false
    local ok
    Setting.browser.apply({ cookie = "new" }, function(value) ok = value end)
    Theme.last("confirm").ok_callback()
    Assert.is_false(ok)
    Assert.eq(cfg.cookie, "old", "清库失败不保存新账号")
    Assert.eq(cfg.account_id, "111")
    clear_ok = true
end

do
    cfg, old_ok = { cookie = "old" }, false
    local ok, err
    Setting.browser.apply({ cookie = "same" }, function(value, reason) ok, err = value, reason end)
    Assert.is_false(ok)
    Assert.matches(err, "无法确认旧账号")
    Assert.eq(cfg.cookie, "old")
    old_ok = true
end

do
    cfg, delay_old = { cookie = "old" }, true
    local called = false
    local job = Setting.browser.apply({ cookie = "same" }, function() called = true end)
    job.cancel()
    late()
    Assert.is_false(called, "取消后旧身份校验不能保存候选账号")
    Assert.eq(cfg.cookie, "old")
end
CookieLogin.fromPayload = original_parse
