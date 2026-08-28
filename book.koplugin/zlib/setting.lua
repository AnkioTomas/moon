--[[--
Z-Library 下载账号设置。

@module koplugin.book.zlib.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")
local Setting = {}

--- 弹出单字段输入框修改 zlib 配置项并落盘。
--- 改动 email/password 会清掉已缓存的 user_id/user_key，强制下次重新登录。
---@param plugin table|nil 保存后用于刷新桌面
---@param key string 配置字段名
---@param title string 对话框标题
---@param hint string 输入框提示
---@param password boolean|nil 是否按密码输入
---@param normalize fun(value: string|nil): string 存盘前的归一化函数
local function edit(plugin, key, title, hint, password, normalize)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local cfg = require("utils.settings").getSource("zlib")
    local dialog
    dialog = InputDialog:new{
        title = title, input = tostring(cfg[key] or ""), input_hint = hint,
        text_type = password and "password" or nil,
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), callback = function()
                cfg[key] = normalize(dialog:getInputText())
                if key == "email" or key == "password" then
                    cfg.user_id, cfg.user_key = nil, nil
                end
                require("utils.settings").saveSource("zlib", cfg)
                UIManager:close(dialog)
                if plugin and plugin.desktop and not plugin.desktop._closed then plugin.desktop:rebuild() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 生成一行设置项的构造器，点击后打开对应字段的编辑框。
---@param plugin table|nil 保存后用于刷新桌面
---@param key string 配置字段名
---@param title string 行标题
---@param hint string 输入框提示
---@param password boolean|nil 是否按密码输入（状态列显示为 ******）
---@param normalize fun(value: string|nil): string 存盘前的归一化函数
---@param icon string|nil 行图标名，缺省 edit
---@return fun(iw: table): table 设置行构造器
local function field(plugin, key, title, hint, password, normalize, icon)
    return function(iw)
        local value = require("utils.settings").getSource("zlib")[key] or ""
        return require("ui.components.settingrow").build(iw, {
            kind = "nav", icon = icon or "edit", title = title,
            status = value ~= "" and (password and "******" or value) or _("未设置"),
            status_on = value ~= "", callback = function()
                edit(plugin, key, title, hint, password, normalize)
            end,
        })
    end
end

--- Z-Library 设置页的行构造器列表：邮箱、密码、镜像地址。
---@param plugin table|nil 保存后用于刷新桌面
---@return table[] 设置行构造器数组，元素为 fun(iw: table): table
function Setting.rows(plugin)
    return {
        field(plugin, "email", _("邮箱"), _("输入邮箱"), false, Text.trim, "mail"),
        field(plugin, "password", _("密码"), _("输入密码"), true, function(value) return value or "" end, "key"),
        field(plugin, "base_url", _("镜像地址"), _("留空自动选择"), false, Text.trim, "dns"),
    }
end

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
