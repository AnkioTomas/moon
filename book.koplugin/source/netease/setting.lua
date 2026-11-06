--[[--
网易云阅读账号。登录页没有扫码：密码直接提交，短信要先在浏览器里填图形码。

@module source.netease.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "netease"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.netease.client").loggedIn()
end

---@param phone string
---@return boolean
local function validPhone(phone)
    if #phone == 11 and phone:match("^%d+$") then return true end
    require("ui.themes.widgets.toast"):new{ text = _("请填写正确的手机号"), timeout = 3 }:show()
    return false
end

local function showLogin()
    local Toast = require("ui.themes.widgets.toast")
    local verification
    local closed = false
    local dialog = require("ui.themes.widgets.input"):new{
        title = _("网易云阅读账号"),
        fields = {
            { label = _("手机号"), text = "", input_type = "number" },
            { label = _("密码"), text = "", text_type = "password" },
            { label = _("短信验证码"), text = "", input_type = "number" },
        },
        ok_text = _("登录"),
        close_callback = function()
            closed = true
            if verification then verification:cancel() end
        end,
        actions = {
            { text = _("获取验证码"), callback = function(phone)
                phone = require("utils.text").trim(phone)
                if not validPhone(phone) then return end
                require("ui/network/manager"):runWhenConnected(function()
                    if closed then return end
                    if verification then verification:cancel() end
                    verification = require("source.netease.verify").new(phone, function(ok, err)
                        Toast:new{
                            text = ok and _("短信已发送，请在设备上填写验证码") or err,
                            timeout = 3,
                        }:show()
                    end)
                end)
            end },
        },
        callback = function(phone, password, code)
            local Text = require("utils.text")
            phone, password, code = Text.trim(phone), Text.trim(password), Text.trim(code)
            if not validPhone(phone) then return end
            local use_password = code == ""
            if use_password and password == "" then
                Toast:new{ text = _("请填写密码或验证码"), timeout = 3 }:show()
                return
            end
            if password ~= "" and (#password < 6 or #password > 16) then
                Toast:new{ text = _("密码长度为 6 到 16 位"), timeout = 3 }:show()
                return
            end
            require("ui/network/manager"):runWhenConnected(function()
                local waiting = require("ui.themes.widgets.progress_dialog"):new{
                    title = _("网易云阅读账号"), text = _("正在登录…"), dismissable = false,
                }
                waiting:show()
                local function done(ok, err)
                    waiting:close()
                    if not ok then
                        Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
                        return
                    end
                    require("source.auth").ok(SOURCE_ID)
                    require("source.registry").reload()
                    Toast:new{ text = _("登录成功"), timeout = 2 }:show()
                end
                local Client = require("source.netease.client")
                if use_password then
                    Client.passwordLoginAsync(phone, password, done)
                else
                    Client.smsLoginAsync(phone, code, password, done)
                end
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
                title = _("网易云阅读账号"),
                subtitle = not status_on and _("图形码在同一 Wi-Fi 的浏览器里填写") or nil,
                status = status, status_on = status_on,
                callback = function() showLogin() end,
            })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出网易云阅读账号？"), function()
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.cookie, cfg.csrf, cfg.logged_in = nil, nil, nil
        settings.saveSource(SOURCE_ID)
        require("source.netease.client").reset()
    end)
    return rows
end

Setting.login = showLogin

return Setting
