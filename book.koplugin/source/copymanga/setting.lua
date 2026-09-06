--[[--
拷贝漫画源设置。

@module koplugin.book.source.copymanga.setting
--]]

require("l10n").apply()
local Client = require("source.copymanga.client")
local _ = require("gettext")

local SOURCE_ID = "copymanga"
local Setting = {}

---@param plugin table|nil
local function afterChanged(plugin)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then
        plugin:onSourceChanged()
    end
end

---@param plugin table|nil
local function editBaseUrl(plugin)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    local dialog
    dialog = InputDialog:new{
        title = _("站点地址"),
        input = Client.normalizeBaseUrl(cfg.base_url),
        input_hint = Client.DEFAULT_BASE_URL,
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("保存"),
                callback = function()
                    cfg.base_url = Client.normalizeBaseUrl(dialog:getInputText())
                    settings.saveSource(SOURCE_ID, cfg)
                    afterChanged(plugin)
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---@param plugin table|nil
---@param username string
---@param password string
local function doLogin(plugin, username, password)
    local Auth = require("source.copymanga.auth")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    NetworkMgr:runWhenOnline(function()
        local waiting = InfoMessage:new{ text = _("正在登录…") }
        UIManager:show(waiting)
        Auth.loginAsync(username, password, function(ok, err)
            UIManager:close(waiting)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = err or _("登录失败"),
                    timeout = 3,
                })
                return
            end
            UIManager:show(InfoMessage:new{
                text = _("登录成功"),
                timeout = 2,
            })
            afterChanged(plugin)
        end)
    end)
end

---@param plugin table|nil
local function showLogin(plugin)
    local Auth = require("source.copymanga.auth")
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local username, password = Auth.credentials()
    if not username then
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        username = tostring(cfg.username or "")
        password = ""
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = _("拷贝漫画账号"),
        fields = {
            {
                text = username,
                hint = _("账号"),
            },
            {
                text = password,
                hint = _("密码"),
                text_type = "password",
            },
        },
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("登录"),
                callback = function()
                    local values = dialog:getFields()
                    UIManager:close(dialog)
                    doLogin(plugin, values[1] or "", values[2] or "")
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---@param plugin table|nil
local function openAccount(plugin)
    local Auth = require("source.copymanga.auth")
    if not Auth.hasSession() then
        showLogin(plugin)
        return
    end

    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local dialog
    dialog = ButtonDialog:new{
        title = _("拷贝漫画账号") .. " · " .. (Auth.userLabel() or ""),
        buttons = {
            {
                {
                    text = _("重新登录"),
                    callback = function()
                        UIManager:close(dialog)
                        local username, password = Auth.credentials()
                        if username then
                            doLogin(plugin, username, password)
                            return
                        end
                        showLogin(plugin)
                    end,
                },
            },
            {
                {
                    text = _("退出登录"),
                    callback = function()
                        Auth.clearSession()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("已退出登录"),
                            timeout = 2,
                        })
                        afterChanged(plugin)
                    end,
                },
            },
            {
                { text = _("取消"), id = "close" },
            },
        },
    }
    UIManager:show(dialog)
end

---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    return {
        function(iw)
            local cfg = require("utils.settings").getSource(SOURCE_ID)
            return require("ui.components.settingrow").build(iw, {
                kind = "nav",
                icon = "dns",
                title = _("站点地址"),
                status = Client.normalizeBaseUrl(cfg.base_url),
                status_on = true,
                callback = function() editBaseUrl(plugin) end,
            })
        end,
        function(iw)
            local Auth = require("source.copymanga.auth")
            local status, status_on
            if Auth.hasSession() then
                status, status_on = Auth.userLabel() or _("已登录"), true
            else
                status, status_on = _("未登录 · 点此登录"), false
            end
            return require("ui.components.settingrow").build(iw, {
                kind = "nav",
                icon = "account_circle",
                title = _("拷贝漫画账号"),
                status = status,
                status_on = status_on,
                callback = function() openAccount(plugin) end,
            })
        end,
    }
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
