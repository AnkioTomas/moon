--[[--
长佩源设置：登录。

长佩网页的登录态是 sessionStorage 里的 token（不是 Cookie，浏览器扩展拿不到）：在电脑浏览器登录
gongzicp.com，开发者工具控制台执行 `sessionStorage.token` 复制出来粘贴。先拉一次账号信息校验，通过才保存。

@module koplugin.book.source.changpei.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "changpei"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.changpei.client").token() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

--- 控制台复制出来的 token 常带引号或空白。
---@param input string
---@return string
function Setting.parseToken(input)
    return (tostring(input):gsub("^[%s\"']+", ""):gsub("[%s\"']+$", ""))
end

---@param token string
local function verify(token)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenOnline(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("长佩账号"), text = _("正在校验登录…"), dismissable = false,
        }
        waiting:show()
        require("source.changpei.client").userAsync(token, function(info, err)
            waiting:close()
            if not info then
                Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
                return
            end
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.token = token
            settings.saveSource(SOURCE_ID, cfg)
            require("source.auth").ok(SOURCE_ID)
            require("source.registry").reload()
            Toast:new{ text = _("登录成功"), timeout = 2 }:show()
        end)
    end)
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("长佩登录 token"),
        fields = { { text = "", hint = _("电脑浏览器登录长佩后，控制台执行 sessionStorage.token 并粘贴") } },
        ok_text = _("登录"),
        callback = function(value)
            local token = Setting.parseToken(value or "")
            if token == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 token"), timeout = 3 }:show()
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
                title = _("长佩账号"), status = status, status_on = status_on,
                callback = function() showLogin() end })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出长佩账号？"),
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
