--[[--
长佩源设置：登录。

长佩网页的登录态是 Cookie（PHPSESSID 等，含 HttpOnly）。没有登录态时服务端要求人机验证、不给正文。
登录三条路：扫码（长佩 App 扫，qrlogin.lua）、浏览器扩展授权（check 靠 JSON code 判定）、或在电脑浏览器登录后把请求里的 Cookie 请求头粘贴进来。
拿到 Cookie 先拉一次账号信息校验，通过才保存。

@module koplugin.book.source.changpei.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "changpei"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.changpei.client").cookie() ~= nil
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

--- 拉一次账号接口校验 Cookie，通过才保存并重载源。
---@param cookie string
---@param cb fun(ok: boolean, err: string|nil)
local function saveCookie(cookie, cb)
    require("source.changpei.client").userAsync(cookie, function(info, err)
        if not info then return cb(false, err or _("登录失败")) end
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.cookie = cookie
        settings.saveSource(SOURCE_ID, cfg)
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
        cb(true)
    end)
end

---@param cookie string
local function verify(cookie)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenConnected(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("长佩账号"), text = _("正在校验登录…"), dismissable = false,
        }
        waiting:show()
        saveCookie(cookie, function(ok, err)
            waiting:close()
            Toast:new{ text = ok and _("登录成功") or err, timeout = ok and 2 or 3 }:show()
        end)
    end)
end

--- 浏览器扩展登录（features/cookie）。getUserInfo 一律 HTTP 200，靠 JSON code 判登录（未登录 9996）。
Setting.browser = {
    domain = "www.gongzicp.com",
    scope = "cookie",
    login = "https://www.gongzicp.com/login/signin",
    check = "https://www.gongzicp.com/webapi/user/getUserInfo",
    check_json = { path = "code", ok = { 200 } },
    icon = "https://www.gongzicp.com/favicon.ico",
    isAuthorized = function()
        return loggedIn() and not require("source.auth").expired(SOURCE_ID)
    end,
    apply = function(payload, cb)
        local parts = {}
        for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
            if type(cookie.name) == "string" and type(cookie.value) == "string" and cookie.value ~= "" then
                parts[#parts + 1] = cookie.name .. "=" .. cookie.value
            end
        end
        if #parts == 0 then return cb(false, _("没有读到 Cookie")) end
        saveCookie(table.concat(parts, "; "), cb)
    end,
}

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.changpei.qrlogin"):new(verify):start()
    end)
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("长佩登录 Cookie"),
        fields = { { text = "", hint = _("登录长佩后，从开发者工具网络面板复制请求头里的 Cookie") } },
        ok_text = _("登录"),
        callback = function(value)
            local cookie = Setting.parseCookie(value or "")
            if cookie == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 Cookie"), timeout = 3 }:show()
                return
            end
            verify(cookie)
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
                callback = function() startQR() end })
        end,
    }
    if not loggedIn() then
        rows[#rows + 1] = function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "content_paste",
                title = _("粘贴 Cookie"), callback = function() showLogin() end })
        end
        return rows
    end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出长佩账号？"),
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

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = startQR

return Setting
