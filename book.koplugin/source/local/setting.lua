--[[--
本地源设置 UI（书库目录由本模块自绘）。
读写：utils.settings.getSource / saveSource("local")

@module koplugin.book.source.local.setting
--]]

local _ = require("gettext")

local SOURCE_ID = "local"

local Setting = {}

--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if type(cfg.webdav_url) == "string" and cfg.webdav_url ~= "" then
        return "WebDAV · " .. cfg.webdav_url, true
    end
    local path = cfg.path or ""
    if path ~= "" then
        return path, true
    end
    return _("未配置"), false
end

---@param plugin table|nil
function Setting.rows(plugin)
    local SettingRow = require("ui.components.settingrow")
    local Text = require("utils.text")
    local function localPathRow(iw)
        local status, on = Setting.rowStatus()
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        if cfg.webdav_url and cfg.webdav_url ~= "" then
            status, on = cfg.path or _("未设置"), cfg.path ~= nil and cfg.path ~= ""
        end
        return SettingRow.build(iw, { kind = "nav", icon = "folder",
            title = _("本地书库目录"), status = status, status_on = on,
            callback = function() Setting.open(plugin) end })
    end
    local function edit(key, title, password)
        local UIManager = require("ui/uimanager")
        local InputDialog = require("ui/widget/inputdialog")
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        local dialog
        dialog = InputDialog:new{ title = title, input = tostring(cfg[key] or ""),
            text_type = password and "password" or nil,
            buttons = {{ text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("保存"), callback = function()
                    cfg[key] = Text.trim(dialog:getInputText())
                    require("utils.settings").saveSource(SOURCE_ID, cfg)
                    require("source.registry").invalidate()
                    UIManager:close(dialog)
                    if plugin and plugin.desktop then plugin.desktop:updateView() end
                end }}}
        UIManager:show(dialog); dialog:onShowKeyboard()
    end
    local function row(key, title, password, icon)
        return function(iw)
            local value = require("utils.settings").getSource(SOURCE_ID)[key] or ""
            return SettingRow.build(iw, { kind = "nav", icon = icon, title = title,
                status = value ~= "" and (password and "******" or value) or _("未设置"),
                status_on = value ~= "", callback = function() edit(key, title, password) end })
        end
    end
    return {
        localPathRow,
        row("webdav_url", _("WebDAV 地址"), false, "dns"),
        row("webdav_username", _("WebDAV 用户名"), false, "person"),
        row("webdav_password", _("WebDAV 密码"), true, "key"),
        row("webdav_path", _("WebDAV 目录"), false, "folder"),
    }
end

--- 目录选择列表：逐层浏览，右上确认当前目录。
---@param plugin table|nil
function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local Popup = require("ui.views.popup")
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    local start_path = cfg.path
    if type(start_path) ~= "string" or start_path == "" then
        local home = G_reader_settings:readSetting("home_dir")
        start_path = type(home) == "string" and home:match("^(.*)/[^/]+/?$") or nil
        if not start_path or start_path == "" then
            local ffiUtil = require("ffi/util")
            local data = require("datastorage"):getFullDataDir()
            start_path = ffiUtil.dirname(ffiUtil.realpath(data) or data)
        end
    end
    Popup.directory{
        title = _("选择书库目录"),
        path = start_path,
        on_select = function(path)
            cfg.path = path
            MoonSettings.saveSource(SOURCE_ID, cfg)
            require("source.registry").invalidate()
            UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
            if plugin and plugin.onSourceChanged then
                plugin:onSourceChanged()
            end
        end,
    }
end

return Setting
