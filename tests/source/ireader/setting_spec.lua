--[[--
掌阅同账号续期与换号保护；浏览器 / Cookie 从 `_zypps` 取 usr/zysid。

@module tests.source.ireader.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }

local cfg, saved, reloaded, callback = { usr = "old", zysid = "original" }, 0, 0, nil
local checks = {}
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saved = saved + 1 end,
}
package.loaded["source.registry"] = { reload = function() reloaded = reloaded + 1 end }
package.loaded["source.auth"] = {
    ok = function() end,
    expired = function() return false end,
}
package.loaded["ui/network/manager"] = {
    runWhenConnected = function(_network, cb) cb() end,
    isConnected = function() return true end,
}
package.loaded["source.ireader.qrlogin"] = {
    new = function(_class, cb)
        callback = cb
        return { start = function() end }
    end,
}
package.loaded["source.ireader.client"] = {
    session = function()
        if cfg.usr and cfg.zysid then return { usr = cfg.usr, zysid = cfg.zysid } end
    end,
    checkSessionAsync = function(user, cb)
        checks[#checks + 1] = user
        cb(true)
        return { cancel = function() end }
    end,
}

package.loaded["source.ireader.setting"] = nil
package.loaded["source.cookie_login"] = nil
local Setting = require("source.ireader.setting")

Setting.open()
callback({ usr = "other", zysid = "candidate" })
Assert.eq(cfg.usr, "old")
Assert.eq(cfg.zysid, "original")
Assert.eq(saved, 0)
Assert.eq(reloaded, 0)
Assert.eq(Themed.last("toast").text, "请先退出当前账号，再登录其他账号")
callback({ usr = "old", zysid = "renewed" })
Assert.eq(cfg.zysid, "renewed")
Assert.eq(saved, 1)
Assert.eq(reloaded, 1)
Assert.eq(Themed.last("toast").text, "登录成功")

Assert.is_true(type(Setting.browser) == "table")
Assert.eq(Setting.browser.domain, "pc.ireader.com")
Assert.is_true(type(Setting.browser.icon) == "string" and Setting.browser.icon:match("^https://"))

local user = Setting.userFromCookie("_zypps=usr%3Dold%26zysid%3Dfromcookie%26name%3D%E6%B5%8B")
Assert.eq(user.usr, "old")
Assert.eq(user.zysid, "fromcookie")

cfg = { usr = "old", zysid = "original" }
saved, reloaded = 0, 0
local rows = Setting.rows()
Assert.eq(rows[2](400).title, "浏览器登录")
Assert.eq(rows[3](400).title, "粘贴 Cookie")
rows[3](400).callback()
local input = Themed.last("input")
Assert.eq(input.title, "掌阅登录 Cookie")
input.callback("Cookie: _zypps=usr%3Dold%26zysid%3Dpasted%26name%3Dx")
Assert.eq(checks[1].usr, "old")
Assert.eq(checks[1].zysid, "pasted")
Assert.eq(cfg.zysid, "pasted")
Assert.eq(saved, 1)

cfg = {}
Setting.browser.apply({ cookies = {
    { domain = ".zhangyue.com", name = "_zypps", value = "usr=new&zysid=browser" },
    { domain = "evil.com", name = "_zypps", value = "usr=x&zysid=y" },
} }, function(ok) Assert.is_true(ok) end)
Assert.eq(cfg.usr, "new")
Assert.eq(cfg.zysid, "browser")
