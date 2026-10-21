--[[--
潇湘源设置：登录。

潇湘手机站的登录态是网页 Cookie：在电脑浏览器登录后，把 m.xxsy.net 请求里的 Cookie 请求头粘贴进来。
站点没有公开的账号校验接口，这里只做格式检查就保存；Cookie 过期表现为已购 VIP 章重新变成「未购」，重新粘贴即可。

@module koplugin.book.source.xiaoxiang.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "xiaoxiang"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.xiaoxiang.client").cookie() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

--- 浏览器复制的 Cookie 请求头（可带 `Cookie:` 前缀）→ 请求头值；没有 `name=value` 返回空串。
---@param input string
---@return string
function Setting.parseCookie(input)
    local text = tostring(input):gsub("^%s*[Cc]ookie%s*:%s*", ""):gsub("[\r\n]+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:find("^[^=%s;]+=") and text or ""
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("潇湘登录 Cookie"),
        fields = { { text = "", hint = _("在电脑浏览器登录潇湘书院手机版后粘贴 Cookie") } },
        ok_text = _("登录"),
        callback = function(value)
            local Toast = require("ui.themes.widgets.toast")
            local cookie = Setting.parseCookie(value or "")
            if cookie == "" then
                Toast:new{ text = _("没有读到 Cookie"), timeout = 3 }:show()
                return
            end
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.cookie = cookie
            settings.saveSource(SOURCE_ID, cfg)
            require("source.registry").reload()
            Toast:new{ text = _("已保存登录 Cookie"), timeout = 2 }:show()
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
                title = _("潇湘账号"), status = status, status_on = status_on,
                callback = function() showLogin() end })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出潇湘账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        local settings = require("utils.settings")
                        local cfg = settings.getSource(SOURCE_ID)
                        cfg.cookie = nil
                        settings.saveSource(SOURCE_ID, cfg)
                        require("ui.themes.widgets.toast"):new{ text = _("已退出登录"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end,
                }:show()
            end })
    end
    return rows
end

Setting.login = showLogin

return Setting
