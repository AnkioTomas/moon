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
local Themed = require("support.theme_stubs")
Themed.install()
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
local begin_cb, wait_cb
local begin_cancels, wait_cancels = 0, 0
package.preload["source.wechat.eink"] = function()
    return {
        beginQrLoginAsync = function(cb)
            begin_cb = cb
            return { cancel = function() begin_cancels = begin_cancels + 1 end }
        end,
        waitQrLoginAsync = function(_, cb)
            wait_cb = cb
            return { cancel = function() wait_cancels = wait_cancels + 1 end }
        end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local auth_changed = 0
package.preload["source.registry"] = function()
    return { reload = function() auth_changed = auth_changed + 1 end }
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
local confirm = Themed.last("confirm")
Assert.is_true(confirm.shown)
confirm.ok_callback()
Assert.is_true(cleared)
Assert.eq(auth_changed, 1)

-- 扫码：先出等待提示，拿到二维码换成 QR 窗；代码换窗不算取消，用户关窗才取消轮询。
logged_in = false
Setting.rows(plugin)[1]().callback()
local waiting = Themed.last("toast")
Assert.eq(waiting.text, "正在获取二维码…")
begin_cb({ uid = "u1", qr_payload = "weread://login?u1" })
Assert.is_true(waiting.closed)
Assert.eq(begin_cancels, 0)
local qr = Themed.last("qr")
Assert.eq(qr.text, "weread://login?u1")
qr:close()
Assert.eq(wait_cancels, 1)
local made = #Themed.made
wait_cb(nil, "迟到", "error")
Assert.eq(#Themed.made, made, "已取消的轮询不再弹提示")

-- 等待中关掉提示：取消取码，迟到的二维码不再弹。
Setting.rows(plugin)[1]().callback()
Themed.last("toast"):close()
Assert.eq(begin_cancels, 1)
made = #Themed.made
begin_cb({ uid = "u2", qr_payload = "x" })
Assert.eq(#Themed.made, made)
