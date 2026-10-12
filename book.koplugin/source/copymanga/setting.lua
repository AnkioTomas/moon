--[[--
拷贝漫画源设置。

@module koplugin.book.source.copymanga.setting
--]]

require("l10n").apply()
local Client = require("source.copymanga.client")
local _ = require("gettext")

local SOURCE_ID = "copymanga"
local Setting = {}

local function editBaseUrl()
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    require("ui.themes.widgets.input"):new{
        title = _("站点地址"),
        fields = { { text = Client.normalizeBaseUrl(cfg.base_url), hint = Client.DEFAULT_BASE_URL } },
        ok_text = _("保存"),
        callback = function(value)
            cfg.base_url = Client.normalizeBaseUrl(value)
            settings.saveSource(SOURCE_ID, cfg)
            require("source.registry").reload()
        end,
    }:show()
end

---@param username string
---@param password string
local function doLogin(username, password)
    local Auth = require("source.copymanga.auth")
    local NetworkMgr = require("ui/network/manager")
    local Toast = require("ui.themes.widgets.toast")
    NetworkMgr:runWhenOnline(function()
        local waiting = Toast:new{ text = _("正在登录…") }
        waiting:show()
        Auth.loginAsync(username, password, function(ok, err)
            waiting:close()
            if not ok then
                Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
                return
            end
            Toast:new{ text = _("登录成功"), timeout = 2 }:show()
            require("source.registry").reload()
        end)
    end)
end

local function showLogin()
    local Auth = require("source.copymanga.auth")
    local username, password = Auth.credentials()
    if not username then
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        username = tostring(cfg.username or "")
        password = ""
    end
    require("ui.themes.widgets.input"):new{
        title = _("拷贝漫画账号"),
        fields = {
            { text = username, hint = _("账号") },
            { text = password, hint = _("密码"), text_type = "password" },
        },
        ok_text = _("登录"),
        callback = function(user, pass) doLogin(user, pass) end,
    }:show()
end

---@return table[]
function Setting.rows()
    local Auth = require("source.copymanga.auth")
    local rows = {
        function(iw)
            local cfg = require("utils.settings").getSource(SOURCE_ID)
            return require("ui.themes.widgets.row").widget({
                width = iw,
                chevron = true,
                kind = "nav",
                icon = "dns",
                title = _("站点地址"),
                status = Client.normalizeBaseUrl(cfg.base_url),
                status_on = true,
                callback = function() editBaseUrl() end,
            })
        end,
        function(iw)
            local status, status_on
            if Auth.hasSession() then
                status, status_on = Auth.userLabel() or _("已登录"), true
            else
                status, status_on = _("未登录 · 点此登录"), false
            end
            return require("ui.themes.widgets.row").widget({
                width = iw,
                chevron = true,
                kind = "nav",
                icon = "account_circle",
                title = _("拷贝漫画账号"),
                status = status,
                status_on = status_on,
                callback = function() showLogin() end,
            })
        end,
    }
    if not Auth.hasSession() then return rows end
    rows[#rows + 1] = function(iw)
        return require("ui.themes.widgets.row").widget({
            width = iw,
            chevron = false,
            kind = "action",
            icon = "logout",
            title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出拷贝漫画账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        Auth.clearSession()
                        require("ui.themes.widgets.toast"):new{ text = _("已退出登录"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end,
                }:show()
            end,
        })
    end
    return rows
end

---@return string, boolean
function Setting.rowStatus()
    local Auth = require("source.copymanga.auth")
    if Auth.hasSession() then
        return Auth.userLabel() or _("已登录"), true
    end
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return Client.normalizeBaseUrl(cfg.base_url), true
end

return Setting
