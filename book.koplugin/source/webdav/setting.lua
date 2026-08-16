--[[--
WebDAV 源设置 UI（连接表单由本模块自绘）。
读写：utils.settings.getSource / saveSource("webdav")

@module koplugin.book.source.webdav.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")

local SOURCE_ID = "webdav"

local Setting = {}


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
