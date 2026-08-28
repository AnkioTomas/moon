--[[--
Moon 源设置 UI（服务器/令牌表单由本模块自绘）。
读写：utils.settings.getSource / saveSource("moon")

@module koplugin.book.source.moon.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")

local SOURCE_ID = "moon"

local Setting = {}

--- 弹出单字段输入框修改 Moon 配置项并落盘。
--- 保存后作废 registry 缓存的源实例，让新地址/令牌立即生效。
---@param plugin table|nil 保存后回调 onSourceChanged 刷新 UI
---@param key string 配置字段名
---@param title string 对话框标题
---@param hint string 输入框提示
---@param password boolean|nil 是否按密码输入
---@param normalize fun(value: string|nil): string 存盘前的归一化函数
local function edit(plugin, key, title, hint, password, normalize)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local SettingRow = require("ui.components.settingrow")
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

--- 生成一行设置项的构造器，点击后打开对应字段的编辑框。
---@param plugin table|nil 保存后回调 onSourceChanged 刷新 UI
---@param key string 配置字段名
---@param title string 行标题
---@param hint string 输入框提示
---@param password boolean|nil 是否按密码输入（状态列显示为 ******）
---@param normalize fun(value: string|nil): string 存盘前的归一化函数
---@param icon string|nil 行图标名，缺省 edit
---@return fun(iw: table): table 设置行构造器
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

--- Moon 设置页的行构造器列表：服务器地址、长期令牌。
---@param plugin table|nil 保存后回调 onSourceChanged 刷新 UI
---@return table[] 设置行构造器数组，元素为 fun(iw: table): table
function Setting.rows(plugin)
    return {
        field(plugin, "base_url", _("服务器地址"), "https://book.example.com", false, Text.stripWhitespace, "dns"),
        field(plugin, "token", _("长期令牌"), "bk_...", true, Text.stripWhitespace, "key"),
    }
end


--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if (cfg.base_url or "") ~= "" and (cfg.token or "") ~= "" then
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
        title = _("服务器与令牌"),
        fields = {
            {
                text = tostring(cfg.base_url or ""),
                hint = _("https://book.example.com"),
            },
            {
                text = tostring(cfg.token or ""),
                hint = _("bk_… 长期令牌"),
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
                    cfg.base_url = Text.stripWhitespace(values[1])
                    cfg.token = Text.stripWhitespace(values[2])
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
