--[[--
Z-Library 下载账号设置。

@module koplugin.book.zlib.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")
local Setting = {}

--- 返回设置入口的状态文案与已登录标记。
---@return string
---@return boolean
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource("zlib")
    if (cfg.user_id or "") ~= "" and (cfg.user_key or "") ~= "" then
        return cfg.email or _("已登录"), true
    end
    if (cfg.email or "") ~= "" then return _("已填写 · 未登录"), false end
    return _("浏览可用 · 下载需登录"), false
end

--- 打开账号和可选镜像地址的编辑对话框。
---@param plugin table|nil 用于保存后刷新桌面
function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("zlib")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Z-Library 账号（下载）"),
        fields = {
            { text = tostring(cfg.email or ""), hint = _("邮箱") },
            { text = tostring(cfg.password or ""), hint = _("密码"), text_type = "password" },
            { text = tostring(cfg.base_url or ""), hint = _("镜像地址（可选，留空自动选择）") },
        },
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), callback = function()
                local values = dialog:getFields()
                cfg.email = Text.trim(values[1])
                cfg.password = values[2] or ""
                local base_url = Text.trim(values[3])
                cfg.base_url = base_url ~= "" and base_url or nil
                cfg.user_id, cfg.user_key = nil, nil
                Settings.saveSource("zlib", cfg)
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
                if plugin and plugin.desktop and not plugin.desktop._closed then plugin.desktop:rebuild() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Setting
