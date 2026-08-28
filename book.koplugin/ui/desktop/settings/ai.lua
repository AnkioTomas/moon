--[[-- AI 服务设置项。
@module koplugin.book.ui.desktop.settings.ai
--]]

require("l10n").apply()

local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local SettingRow = require("ui.components.settingrow")
local Settings = require("utils.settings")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local AI = {}

--- 弹输入框编辑一项 AI 配置，保存后写入 ai 分区并重建桌面。
---@param desktop table 桌面实例
---@param key string ai 配置键名
---@param title string 对话框标题，也是设置行标题
---@param hint string 输入框占位提示
---@param password boolean 是否按密码遮蔽输入
---@param normalize fun(value: string): string 落盘前的规范化（去空白、去尾斜杠等）
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

--- 造一个 AI 配置项设置行的构造器；密码项状态只显示星号。
---@param desktop table 桌面实例
---@param key string ai 配置键名
---@param title string 设置行标题
---@param hint string 输入框占位提示
---@param password boolean 是否按密码遮蔽
---@param normalize fun(value: string): string 落盘前的规范化
---@return fun(iw: number): table
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

--- 点按后发一条最小 chat（小 max_tokens），成功显示返回摘要，失败显示错误。
---@param desktop table
---@return function
local function testRow(desktop)
    local testing = false
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action", icon = "network_check", title = _("测试连接"),
            callback = function()
                if testing then
                    return
                end
                if not require("ai").isConfigured() then
                    UIManager:show(InfoMessage:new{ text = _("请先配置接口地址、API 密钥和模型"), timeout = 2 })
                    return
                end
                testing = true
                local loading = InfoMessage:new{ text = _("正在测试…") }
                UIManager:show(loading)
                require("ai").chat({ { role = "user", content = "ping" } },
                    { max_tokens = 64 },
                    function(content, err)
                        testing = false
                        UIManager:close(loading)
                        if desktop._closed then
                            return
                        end
                        local text
                        if content then
                            text = T(_("连接正常，模型回复：%1"), Text.trim(content):sub(1, 50))
                        else
                            text = T(_("测试失败：%1"), tostring(err))
                        end
                        UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
                    end)
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
        testRow(desktop),
    }
end

return AI
