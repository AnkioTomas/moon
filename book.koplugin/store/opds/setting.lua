--[[--
OPDS 目录设置：地址 + 可选 HTTP Basic 账号。地址留空即关闭底栏 OPDS。

@module koplugin.book.store.opds.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")
local Setting = {}

--- 返回设置入口的状态文案与已配置标记。
---@return string
---@return boolean
function Setting.rowStatus()
    local url = Text.trim(require("utils.settings").getSource("opds").url)
    if url == "" then return _("未配置"), false end
    return url:match("^%a[%w+.-]*://([^/?#]+)") or url, true
end

--- 规范化并落盘（设备对话框与远程配置共用）。地址缺协议时补 http://，空值存 nil。
---@param url string|nil
---@param username string|nil
---@param password string|nil
---@return boolean changed
function Setting.save(url, username, password)
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("opds")
    url, username = Text.trim(url), Text.trim(username)
    if url ~= "" and not url:match("^%a[%w+.-]*://") then url = "http://" .. url end
    local next_url = url ~= "" and url or nil
    local next_user = username ~= "" and username or nil
    local next_pass = password ~= nil and password ~= "" and password or nil
    if cfg.url == next_url and cfg.username == next_user and cfg.password == next_pass then return false end
    cfg.url, cfg.username, cfg.password = next_url, next_user, next_pass
    Settings.saveSource("opds", cfg)
    -- 换账号后 5 分钟 feed 缓存里可能是旧账号的结果（或 401）。
    if next_url then require("http.cache").clear(next_url:match("^%a[%w+.-]*://[^/?#]+")) end
    return true
end

--- 打开地址与账号编辑对话框。
function Setting.open()
    local cfg = require("utils.settings").getSource("opds")
    require("ui.themes.widgets.input"):new{
        title = _("OPDS 目录"),
        fields = {
            { text = tostring(cfg.url or ""), hint = _("目录地址，如 http://192.168.1.2:8083/opds") },
            { text = tostring(cfg.username or ""), hint = _("用户名（可选）") },
            { text = tostring(cfg.password or ""), hint = _("密码（可选）"), text_type = "password" },
        },
        ok_text = _("保存"),
        callback = function(url, username, password)
            Setting.save(url, username, password)
            require("ui.themes.widgets.toast"):new{ text = _("已保存"), timeout = 2 }:show()
            require("ui/uimanager"):broadcastEvent(require("ui/event"):new("StoreChanged"))
        end,
    }:show()
end

return Setting
