--[[--
拷贝漫画源设置 UI。
读写：utils.settings.getSource / saveSource("copymanga")

@module koplugin.book.source.copymanga.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local SOURCE_ID = "copymanga"

local Setting = {}

local function afterAuthChanged(plugin)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then
        plugin:onSourceChanged()
    end
end

function Setting.rowStatus()
    local Auth = require("source.copymanga.auth")
    if Auth.hasSession() then
        return Auth.userLabel() or _("已登录"), true
    end
    return _("未登录"), false
end

function Setting.rowTitle()
    return _("拷贝漫画账号")
end

function Setting.rowIcon()
    return "person"
end

local function edit(plugin, key, title, hint, password, normalize)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(cfg[key] or ""),
        input_hint = hint,
        text_type = password and "password" or nil,
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), callback = function()
                cfg[key] = normalize(dialog:getInputText())
                require("utils.settings").saveSource(SOURCE_ID, cfg)
                require("source.registry").invalidate()
                UIManager:close(dialog)
                if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function field(plugin, key, title, hint, password, normalize, icon)
    return function(iw)
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        local value = cfg[key] or ""
        local status, status_on
        if key == "api_host" then
            local Auth = require("source.copymanga.auth")
            local effective = Auth.apiHost(cfg)
            if value == "" then
                status = effective .. _("（默认）")
                status_on = true
            else
                status = effective
                status_on = true
            end
        else
            status = value ~= "" and (password and "******" or value) or _("未设置")
            status_on = value ~= ""
        end
        return require("ui.components.settingrow").build(iw, {
            kind = "nav", icon = icon or "edit", title = title,
            status = status,
            status_on = status_on,
            callback = function()
                edit(plugin, key, title, hint, password, normalize)
            end,
        })
    end
end

function Setting.rows(plugin)
    local Auth = require("source.copymanga.auth")
    local rows = {
        field(plugin, "api_host", _("API 主机"), "api.copy4000.com", false, Text.stripWhitespace, "dns"),
        field(plugin, "username", _("账号"), "", false, Text.stripWhitespace, "person"),
        field(plugin, "password", _("密码"), "", true, function(s) return s end, "key"),
    }
    rows[#rows + 1] = function(iw)
        local logged_in = Auth.hasSession()
        return require("ui.components.settingrow").build(iw, {
            kind = "action",
            icon = logged_in and "logout" or "login",
            title = logged_in and _("退出登录") or _("登录"),
            status = logged_in and _("已登录") or _("未登录"),
            status_on = logged_in,
            callback = function()
                if logged_in then
                    Auth.logout()
                    afterAuthChanged(plugin)
                    return
                end
                local cfg = require("utils.settings").getSource(SOURCE_ID)
                local username = Text.stripWhitespace(cfg.username or "")
                local password = tostring(cfg.password or "")
                if username == "" or password == "" then
                    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                        text = _("请先填写账号和密码"),
                        timeout = 2,
                    })
                    return
                end
                require("ui/network/manager"):runWhenOnline(function()
                    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                        text = _("正在登录…"),
                        timeout = 1,
                    })
                    Auth.loginAsync(username, password, function(ok, err)
                        if ok then
                            afterAuthChanged(plugin)
                            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                                text = _("登录成功"),
                                timeout = 2,
                            })
                        else
                            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                                text = err or _("登录失败"),
                                timeout = 3,
                            })
                        end
                    end)
                end)
            end,
        })
    end
    return rows
end

function Setting.open(plugin)
    local Popup = require("ui.components.popup")
    Popup.page{
        title = _("拷贝漫画"),
        sections = {{ rows = Setting.rows(plugin) }},
    }
end

return Setting
