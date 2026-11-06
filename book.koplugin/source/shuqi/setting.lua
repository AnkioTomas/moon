--[[--
书旗账号：手机验证码。滑块在同一 Wi-Fi 的浏览器里完成，短信码回到设备填写。

@module source.shuqi.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "shuqi"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.shuqi.client").loggedIn()
end

local function showLogin()
    local Toast = require("ui.themes.widgets.toast")
    local verification, dialog
    local agreed, closed = false, false
    local function consent(run)
        if agreed then return run() end
        require("ui.themes.widgets.confirm"):new{
            title = _("书旗账号"),
            text = _("未注册的手机号将自动注册书旗账号。继续即同意书旗用户协议和隐私政策。"),
            ok_text = _("同意并继续"),
            ok_callback = function() agreed = true; run() end,
        }:show()
    end
    local function validPhone(phone)
        if #phone == 11 and phone:match("^1%d+$") then return true end
        Toast:new{ text = _("请填写正确的手机号"), timeout = 3 }:show()
        return false
    end
    dialog = require("ui.themes.widgets.input"):new{
        title = _("书旗账号"),
        fields = {
            { label = _("手机号"), text = "", input_type = "number" },
            { label = _("验证码"), text = "", input_type = "number" },
        },
        ok_text = _("登录"),
        close_callback = function()
            closed = true
            if verification then verification:cancel() end
        end,
        actions = {
            { text = _("发送验证码"), callback = function(phone)
                phone = require("utils.text").trim(phone)
                if not validPhone(phone) then return end
                consent(function()
                    require("ui/network/manager"):runWhenConnected(function()
                        if closed then return end
                        if verification then verification:cancel() end
                        verification = require("source.shuqi.verify").new(phone, function(ok, err)
                            Toast:new{ text = ok and _("短信已发送，请在设备上填写验证码") or err, timeout = 3 }:show()
                        end)
                    end)
                end)
            end },
        },
        callback = function(phone, code)
            phone, code = require("utils.text").trim(phone), require("utils.text").trim(code)
            if not validPhone(phone) then return end
            if code == "" then
                Toast:new{ text = _("请先填写验证码"), timeout = 3 }:show()
                return
            end
            consent(function()
                require("ui/network/manager"):runWhenConnected(function()
                    local waiting = require("ui.themes.widgets.progress_dialog"):new{
                        title = _("书旗账号"), text = _("正在登录…"), dismissable = false,
                    }
                    waiting:show()
                    local browser = require("source.shuqi.verify").browser()
                    require("source.shuqi.client").loginAsync(phone, code, browser, function(session, err)
                        waiting:close()
                        if not session then
                            Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
                            return
                        end
                        require("source.auth").ok(SOURCE_ID)
                        require("source.registry").reload()
                        Toast:new{ text = _("登录成功"), timeout = 2 }:show()
                    end)
                end)
            end)
        end,
    }
    dialog:show()
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("书旗账号"),
                subtitle = not status_on and _("滑块在同一 Wi-Fi 的浏览器里完成") or nil,
                status = status, status_on = status_on,
                callback = function() showLogin() end,
            })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出书旗账号？"), function()
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.token, cfg.user_id, cfg.name = nil, nil, nil
        cfg.logged_in, cfg.imei, cfg.umidtoken, cfg.wua = nil, nil, nil, nil
        settings.saveSource(SOURCE_ID)
        require("source.shuqi.client").reset()
    end)
    return rows
end

Setting.login = showLogin

return Setting
