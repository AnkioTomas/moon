--[[--
微信读书设置页行：账号 / 同步阅读时间直接是设置行，登录后才追加续期与退出。

@module tests.source.wechat.setting_spec
--]]

local Assert = require("support.assert")

local cfg = {}
local saved = 0
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_, value) cfg = value; saved = saved + 1 end,
    }
end
local logged_in = false
local cleared = false
package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function() return logged_in end,
        userLabel = function() return "tester" end,
        clearSession = function() cleared = true; logged_in = false end,
    }
end
local shown = {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, w) shown[#shown + 1] = w end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, o) o.kind = "confirm"; return o end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
local auth_changed = 0
package.preload["source.registry"] = function()
    return { afterAuthChanged = function() auth_changed = auth_changed + 1 end }
end

package.loaded["source.wechat.setting"] = nil
local Setting = require("source.wechat.setting")
local updates = 0
local plugin = { desktop = { updateView = function() updates = updates + 1 end } }

-- 未登录：只有账号行与同步阅读时间行；同步默认开启，副标题写明需联网。
local rows = Setting.rows(plugin)
Assert.len(rows, 2)
Assert.eq(rows[1]().status, "未登录 · 点此扫码")
local sync = rows[2]()
Assert.eq(sync.kind, "toggle")
Assert.eq(sync.status, "开", "缺省即开启")
Assert.is_true(sync.status_on)
Assert.matches(sync.subtitle, "联网")

-- 点按切换：落盘 false 并刷新设置页；再点恢复 true。
sync.callback()
Assert.eq(cfg.sync_reading_time, false)
Assert.eq(saved, 1)
Assert.eq(updates, 1)
Assert.eq(rows[2]().status, "关")
rows[2]().callback()
Assert.eq(cfg.sync_reading_time, true)

-- 已登录：追加续期与退出；退出先确认，确认后才清会话。
logged_in = true
rows = Setting.rows(plugin)
Assert.len(rows, 4)
Assert.eq(rows[1]().status, "tester")
Assert.eq(rows[3]().title, "续期会话")
local logout = rows[4]()
Assert.eq(logout.title, "退出登录")
logout.callback()
Assert.is_false(cleared, "未确认不退出")
local confirm = shown[#shown]
Assert.eq(confirm.kind, "confirm")
confirm.ok_callback()
Assert.is_true(cleared)
Assert.eq(auth_changed, 1)

return true
