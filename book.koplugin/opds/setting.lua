--[[--
OPDS 目录设置：地址 + 可选 HTTP Basic 账号。地址留空即关闭底栏 OPDS。

@module koplugin.book.opds.setting
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
    if next_url then require("http.request").clearCache(next_url:match("^%a[%w+.-]*://[^/?#]+")) end
    return true
end

--- 打开地址与账号编辑对话框。
---@param plugin table|nil 保存后经 onSourceChanged 重算底栏
function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local cfg = require("utils.settings").getSource("opds")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("OPDS 目录"),
        fields = {
            { text = tostring(cfg.url or ""), hint = _("目录地址，如 http://192.168.1.2:8083/opds") },
            { text = tostring(cfg.username or ""), hint = _("用户名（可选）") },
            { text = tostring(cfg.password or ""), hint = _("密码（可选）"), text_type = "password" },
        },
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), callback = function()
                local values = dialog:getFields()
                Setting.save(values[1], values[2], values[3])
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
                if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Setting
