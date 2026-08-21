--[[-- AI 服务设置项。
@module koplugin.book.ui.desktop.settings.ai
--]]

require("l10n").apply()

local InputDialog = require("ui/widget/inputdialog")
local SettingRow = require("ui.components.settingrow")
local Settings = require("utils.settings")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local AI = {}

local function edit(desktop, key, title, hint, password, normalize)
    local cfg = Settings.get("ai")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(cfg[key] or ""),
        input_hint = hint,
        text_type = password and "password" or nil,
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), is_enter_default = true, callback = function()
                cfg[key] = normalize(dialog:getInputText())
                Settings.saveSection("ai", cfg)
                UIManager:close(dialog)
                desktop:rebuild()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function row(desktop, key, title, hint, password, normalize)
    return function(iw)
        local value = Settings.get("ai")[key] or ""
        local status = value ~= "" and (password and "******" or value) or _("未设置")
        return SettingRow.build(iw, {
            kind = "nav", icon = password and "key" or "edit", title = title,
            status = status, status_on = value ~= "", callback = function()
                edit(desktop, key, title, hint, password, normalize)
            end,
        })
    end
end

---@param desktop table
---@return table
function AI.rows(desktop)
    return {
        row(desktop, "ai_endpoint", _("接口地址"), "https://api.example.com/v1", false,
            function(value) return Text.rtrimSlashes(Text.trim(value)) end),
        row(desktop, "ai_api_key", _("API 密钥"), _("输入 API 密钥"), true,
            function(value) return Text.trim(value) end),
        row(desktop, "ai_model", _("模型"), _("输入模型名"), false,
            function(value) return Text.trim(value) end),
    }
end

return AI
