--[[--
七猫手机号 / 短信码留在本机；仅发送短信前的拼图桥接，保留 token 导入。

@module tests.source.qimao.login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
require("source.logout").replaceLibrary = function(id, commit)
    Assert.eq(id, "qimao")
    commit()
    return true
end
Themed.install()
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(spec) return spec end }
end
local Progress = require("ui.themes.widgets.progress_dialog")
local newProgress = Progress.new
function Progress:new(spec)
    local dialog = newProgress(self, spec)
    dialog.show = function(self) self.shown = true end
    return dialog
end
local cfg = { token = "old-token" }
local saved, reloaded, authorized
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_id, value) saved = value.token end,
    }
end
package.preload["source.auth"] = function()
    return { ok = function(id) authorized = id end, expired = function() return false end }
end
package.preload["source.registry"] = function() return { reload = function() reloaded = true end } end
local pending_network, defer_network
package.preload["ui/network/manager"] = function()
    return { runWhenConnected = function(_self, fn)
        if defer_network then pending_network = fn else fn() end
    end }
end
local sessions = {}
package.preload["source.qimao.verify"] = function()
    return { new = function(phone, cb)
        local session = { phone = phone, callback = cb }
        session.cancel = function() session.cancelled = true end
        sessions[#sessions + 1] = session
        return session
    end }
end
local login_phone, login_code, checked_token
local login_error
package.preload["source.qimao.client"] = function()
    return {
        token = function() return cfg.token end,
        loginAsync = function(phone, code, cb)
            login_phone, login_code = phone, code
            cb(login_error and nil or "new-token", login_error)
        end,
        userInfoAsync = function(token, cb) checked_token = token; cb({}) end,
    }
end
local Setting = require("source.qimao.setting")
Setting.login()
local input = Themed.last("input")
Assert.len(input.fields, 2)
Assert.eq(input.fields[1].label, "手机号")
Assert.eq(input.fields[2].label, "验证码")
Assert.len(input.actions, 1, "手机号登录只留发码动作，避免四个按钮挤在一行")
input.actions[1].callback("invalid")
Assert.len(sessions, 0)
Assert.eq(Themed.last("toast").text, "请填写正确的手机号")
input.actions[1].callback(" 13800000000 ")
Assert.len(sessions, 0, "用户同意协议之前不启动发短信验证")
Themed.last("confirm").ok_callback()
Assert.len(sessions, 1)
Assert.eq(sessions[1].phone, "13800000000")
sessions[1].callback(true)
Assert.eq(Themed.last("toast").text, "短信已发送，请在设备上填写验证码")
Assert.is_nil(input.closed, "滑块完成后仍在设备填写短信码")
input.actions[1].callback("13800000000")
Assert.is_true(sessions[1].cancelled, "重复点击只保留最新一次发送")
Assert.len(sessions, 2)
input:close()
input.callback("13800000000", "001234")
Assert.is_true(sessions[2].cancelled)
Assert.eq(login_phone, "13800000000")
Assert.eq(login_code, "001234")
Assert.eq(checked_token, "new-token", "登录返回的 token 仍先校验")
Assert.eq(saved, "new-token")
Assert.eq(authorized, "qimao")
Assert.is_true(reloaded)
Assert.is_nil(cfg.phone, "不持久化手机号或短信码")
Assert.is_nil(cfg.code)
Assert.is_true(Themed.last("progress_dialog").closed)

local token_row
for _idx, make_row in ipairs(Setting.rows()) do
    local row = make_row(400)
    if row.title == "用 token 登录" then
        token_row = row
        break
    end
end
Assert.not_nil(token_row, "保留 token 登录入口，不依赖账号页行顺序")
token_row.callback()
local imported = Themed.last("input")
Assert.eq(imported.title, "七猫登录 token")
Assert.len(imported.fields, 1)
imported.callback("manual-token")
Assert.eq(saved, "manual-token", "保留旧 token 登录入口")

Setting.login()
input = Themed.last("input")
defer_network = true
input.actions[1].callback("13800000000")
Themed.last("confirm").ok_callback()
Assert.not_nil(pending_network)
input:close()
pending_network()
Assert.len(sessions, 2, "等待联网时关闭输入窗不能再弹出二维码")

defer_network = false
Setting.login()
input = Themed.last("input")
input:close()
input.callback("13800000000", "")
Assert.eq(Themed.last("toast").text, "请先填写验证码")
