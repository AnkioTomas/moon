--[[--
WebDAV 源设置 UI（连接表单由本模块自绘）。
读写：utils.settings.getSource / saveSource("webdav")

@module koplugin.book.source.webdav.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")

local SOURCE_ID = "webdav"

local Setting = {}

local function edit(plugin, key, title, hint, password, normalize)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local dialog
    dialog = InputDialog:new{
        title = title, input = tostring(cfg[key] or ""), input_hint = hint,
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
        local value = require("utils.settings").getSource(SOURCE_ID)[key] or ""
        return require("ui.components.settingrow").build(iw, {
            kind = "nav", icon = icon or "edit", title = title,
            status = value ~= "" and (password and "******" or value) or _("未设置"),
            status_on = value ~= "", callback = function()
                edit(plugin, key, title, hint, password, normalize)
            end,
        })
    end
end

function Setting.rows(plugin)
    return {
        field(plugin, "url", _("服务器地址"), "https://dav.example.com/dav/", false, Text.stripWhitespace, "dns"),
        field(plugin, "username", _("用户名"), _("输入用户名"), false, Text.stripWhitespace, "person"),
        field(plugin, "password", _("密码"), _("输入密码"), true, function(value) return value or "" end, "key"),
    }
end


--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if (cfg.url or "") ~= "" then
        return _("已配置"), true
    end
    return _("未配置"), false
end

--- 自绘连接表单。
---@param plugin table|nil
function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("WebDAV 配置"),
        fields = {
            {
                text = tostring(cfg.url or ""),
                hint = _("https://dav.example.com/dav/"),
            },
            {
                text = tostring(cfg.username or ""),
                hint = _("用户名"),
            },
            {
                text = tostring(cfg.password or ""),
                hint = _("密码"),
                text_type = "password",
            },
        },
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local values = dialog:getFields()
                    cfg.url = Text.stripWhitespace(values[1])
                    cfg.username = Text.stripWhitespace(values[2])
                    cfg.password = values[3] or ""
                    MoonSettings.saveSource(SOURCE_ID, cfg)
                    require("source.registry").invalidate()
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
                    if plugin and plugin.onSourceChanged then
                        plugin:onSourceChanged()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Setting
