--[[--
掌阅同账号续期与换号保护，不覆盖旧登录或把旧脏行推给新账号。

@module tests.source.ireader.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local cfg, saved, reloaded, callback = { usr = "old", zysid = "original" }, 0, 0, nil
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saved = saved + 1 end,
}
package.loaded["source.registry"] = { reload = function() reloaded = reloaded + 1 end }
package.loaded["source.ireader.qrlogin"] = {
    new = function(_class, cb)
        callback = cb
        return { start = function() end }
    end,
}
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
