--[[-- AI 服务设置项。
@module koplugin.book.ui.desktop.settings.ai
--]]

require("l10n").apply()

local Settings = require("utils.settings")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local AI = {}

--- 打开 AI 服务配置对话框（端点 / 密钥 / 模型）。
---@param desktop table
function AI.open(desktop)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local current = Settings.get()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("AI 服务"),
        fields = {
            { text = current.ai_endpoint or "", hint = _("接口地址") },
            { text = current.ai_api_key or "", hint = _("API 密钥"), text_type = "password" },
            { text = current.ai_model or "", hint = _("模型") },
        },
        buttons = { {
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("保存"), is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    current.ai_endpoint = Text.rtrimSlashes(Text.trim(fields[1]))
                    current.ai_api_key = Text.trim(fields[2])
                    current.ai_model = Text.trim(fields[3])
                    Settings.save(current)
                    UIManager:close(dialog)
                    desktop:rebuild()
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return AI
