--[[--
Z-Library 下载账号设置。

@module koplugin.book.store.zlib.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")
local Setting = {}

--- 返回设置入口的状态文案与已登录标记。
---@return string
---@return boolean
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource("zlib")
    if require("store.zlib.client").new(cfg):hasSession() then
        return cfg.email or _("已登录"), true
    end
    if (cfg.email or "") ~= "" then return _("已填写 · 未登录"), false end
    return _("浏览可用 · 下载需登录"), false
end

--- 打开账号和可选镜像地址的编辑对话框。
---@param plugin table|nil 用于保存后刷新桌面
function Setting.open(plugin)
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("zlib")
    require("ui.themes.widgets.input"):new{
        title = _("Z-Library 账号"),
        fields = {
            { text = cfg.email or "", hint = _("邮箱") },
            { text = cfg.password or "", hint = _("密码"), text_type = "password" },
            { text = cfg.base_url or "", hint = _("镜像地址（可选，留空自动选择）") },
        },
        ok_text = _("保存"),
        callback = function(email, password, base_url)
            cfg.email = Text.trim(email)
            cfg.password = password
            base_url = Text.trim(base_url)
            cfg.base_url = base_url ~= "" and base_url or nil
            cfg.user_id, cfg.user_key = nil, nil
            Settings.saveSource("zlib", cfg)
            require("ui.themes.widgets.toast"):new{ text = _("已保存"), timeout = 2 }:show()
            if plugin and plugin.desktop then plugin.desktop:updateView() end
        end,
    }:show()
end

return Setting
