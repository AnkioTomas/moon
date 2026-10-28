--[[--
潇湘源设置：登录。

潇湘账号在新站 www.xxsypro.com（阅文通行证，只有 QQ / 微信 / 阅文账号，没有扫码）。登录态是网页 Cookie：
浏览器扩展授权（check 靠 personal 接口 data.isLogin），或在电脑浏览器登录后把请求里的 Cookie 请求头粘贴进来。拿到 Cookie 先校验再保存。

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

--- 拉一次账号接口校验 Cookie，通过才保存并重载源。
---@param cookie string
---@param cb fun(ok: boolean, err: string|nil)
local function saveCookie(cookie, cb)
    require("source.xiaoxiang.client").userAsync(cookie, function(info, err)
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
            title = _("潇湘账号"), text = _("正在校验登录…"), dismissable = false,
        }
        waiting:show()
        saveCookie(cookie, function(ok, err)
            waiting:close()
            Toast:new{ text = ok and _("登录成功") or err, timeout = ok and 2 or 3 }:show()
        end)
    end)
end

--- 浏览器扩展登录（features/cookie）。personal 接口一律 code 0，靠 data.isLogin 判登录。
Setting.browser = {
    domain = "www.xxsypro.com",
    scope = "cookie",
    login = "https://www.xxsypro.com/",
    check = "https://www.xxsypro.com/api/user/auth/personal",
    check_json = { path = "data.isLogin", ok = { 1 } },
    icon = "https://www.xxsypro.com/favicon.ico",
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

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("潇湘登录 Cookie"),
        fields = { { text = "", hint = _("登录 www.xxsypro.com 后，从开发者工具网络面板复制请求头里的 Cookie") } },
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
