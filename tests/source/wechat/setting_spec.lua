--[[--
微信读书设置页行：账号直接是设置行，登录后才追加续期与退出。

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
    return { runWhenConnected = function(_, fn) fn() end }
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

-- 未登录：账号、合并本地阅读时长、显示段评三行。
local rows = Setting.rows(plugin)
Assert.len(rows, 3)
Assert.eq(rows[1]().status, "未登录 · 点此扫码")

-- 合并本地阅读时长默认关（云端优先）；点按落盘开启并刷新设置页。
local merge = rows[2]()
Assert.eq(merge.kind, "toggle")
Assert.eq(merge.title, "合并本地阅读时长")
Assert.is_false(merge.status_on)
merge.callback()
Assert.is_true(cfg.merge_local_stats)
Assert.eq(saved, 1)
Assert.eq(updates, 1)
Assert.is_true(rows[2]().status_on)

-- 段评默认关；点按落盘开启。
local reviews = rows[3]()
Assert.eq(reviews.title, "显示段评")
Assert.is_false(reviews.status_on)
reviews.callback()
Assert.is_true(cfg.show_paragraph_reviews)
Assert.is_true(rows[3]().status_on)

-- 已登录：追加续期与退出；退出先确认，确认后才清会话。
logged_in = true
rows = Setting.rows(plugin)
Assert.len(rows, 5)
Assert.eq(rows[1]().status, "tester")
Assert.eq(rows[4]().title, "续期会话")
local logout = rows[5]()
Assert.eq(logout.title, "退出登录")
logout.callback()
Assert.is_false(cleared, "未确认不退出")
local confirm = Themed.last("confirm")
Assert.is_true(confirm.shown)
confirm.ok_callback()
Assert.is_true(cleared)
Assert.eq(auth_changed, 1)

-- 扫码：先出不可取消的进度窗，拿到二维码换成 QR 窗；代码换窗不算取消，用户关窗才取消轮询。
logged_in = false
Setting.rows(plugin)[1]().callback()
local waiting = Themed.last("progress_dialog")
Assert.eq(waiting.text, "正在获取二维码…")
Assert.eq(waiting.dismissable, false)
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

