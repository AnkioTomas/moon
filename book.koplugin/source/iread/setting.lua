--[[--
iRead 源设置：个人 Token。

在 iread.ankio.net 登录后打开「个人 Token」页创建 Token，复制粘贴进来；粘贴时先向服务端校验，通过才保存并重载源。

@module koplugin.book.source.iread.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local SOURCE_ID = "iread"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.iread.client").token() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此填写 Token"), on
end

--- 接受裸 Token，或带 `Bearer ` 前缀的整段。
---@param input string
---@return string
function Setting.parseToken(input)
    return (require("utils.text").trim(input):gsub("^[Bb]earer%s+", ""))
end

---@param token string
local function verify(token)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenOnline(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("iRead"), text = _("正在校验 Token…"), dismissable = false,
        }
        waiting:show()
        require("source.iread.client").userAsync(token, function(user, err)
            waiting:close()
            if not user then
                Toast:new{ text = err or _("Token 无效"), timeout = 3 }:show()
                return
            end
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.token = token
            settings.saveSource(SOURCE_ID, cfg)
            require("source.registry").reload()
            Toast:new{ text = T(_("已登录：%1"), user.nickname), timeout = 2 }:show()
        end)
    end)
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("iRead 个人 Token"),
        fields = { { text = "", hint = _("在 iread.ankio.net 的个人 Token 页创建后粘贴") } },
        ok_text = _("登录"),
        callback = function(value)
            local token = Setting.parseToken(value or "")
            if token == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 Token"), timeout = 3 }:show()
                return
            end
            verify(token)
        end,
    }:show()
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("iRead 账号"), status = status, status_on = status_on,
                callback = function() showLogin() end })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出 iRead 账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        local settings = require("utils.settings")
                        local cfg = settings.getSource(SOURCE_ID)
                        cfg.token = nil
                        settings.saveSource(SOURCE_ID, cfg)
                        require("ui.themes.widgets.toast"):new{ text = _("已退出登录"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end,
                }:show()
            end })
    end
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = showLogin

return Setting
