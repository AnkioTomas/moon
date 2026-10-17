--[[--
QQ阅读源设置：登录。

设备上扫阅文二维码（QQ阅读或起点 App）。浏览器扩展绑定保留：login/check 必须是
book.qq.com 下的 HTTPS，不能指到 passport。书架页未登录也是 200，扩展会立刻回传 Cookie。
扫码、粘贴、扩展三条路都先打 /api/user/homepage，code 不是 0 就不保存。

@module koplugin.book.source.qqreader.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "qqreader"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.qqreader.client").cookie() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

---@param name any
---@param value any
---@return boolean
local function validPair(name, value)
    return type(name) == "string" and name:match("^[%w_%-%.]+$") ~= nil
        and type(value) == "string" and value ~= "" and not value:find("[;\r\n]")
end

---@param jar table<string, string>
---@return string
local function cookieHeader(jar)
    local keys = {}
    for key in pairs(jar) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do parts[i] = key .. "=" .. jar[key] end
    return table.concat(parts, "; ")
end

--- 浏览器里复制的 Cookie 请求头（`a=1; b=2`）→ Cookie 请求头；格式不对的项丢弃，一项都没有返回空串。
---@param input string
---@return string
function Setting.parseCookie(input)
    local jar = {}
    for pair in tostring(input):gmatch("[^;]+") do
        local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if validPair(name, value) then jar[name] = value end
    end
    return cookieHeader(jar)
end

--- 浏览器扩展交来的 payload.cookies → Cookie 请求头；只收 QQ阅读站点的 Cookie。
---@param payload table
---@return string
function Setting.fromPayload(payload)
    local jar = {}
    for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
        local domain = type(cookie) == "table" and type(cookie.domain) == "string"
            and cookie.domain:gsub("^%.", ""):lower()
        if domain and (domain == "qq.com" or domain:match("%.qq%.com$")) and validPair(cookie.name, cookie.value) then
            jar[cookie.name] = cookie.value
        end
    end
    return cookieHeader(jar)
end

--- 拉一次账号接口校验 Cookie，通过才保存并重载源。
---@param cookie string
---@param cb fun(ok: boolean, err: string|nil)
local function saveCookie(cookie, cb)
    if cookie == "" then return cb(false, _("没有读到 Cookie")) end
    require("source.qqreader.client").loginCheckAsync(cookie, function(ok, err)
        if not ok then return cb(false, err or _("登录失败")) end
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
    require("ui/network/manager"):runWhenOnline(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("QQ阅读账号"), text = _("正在校验登录…"), dismissable = false,
        }
        waiting:show()
        saveCookie(cookie, function(ok, err)
            waiting:close()
            Toast:new{ text = ok and _("登录成功") or err, timeout = ok and 2 or 3 }:show()
        end)
    end)
end

--- 浏览器扩展登录（features/cookie）。
Setting.browser = {
    domain = "book.qq.com",
    scope = "cookie",
    -- 必须是 domain 下的 HTTPS。未登录书架页不跳 passport，校验在 apply 里打账号接口。
    login = "https://book.qq.com/book-shelf",
    check = "https://book.qq.com/book-shelf",
    icon = "https://imgservices-1252317822.file.myqcloud.com/image/090120210101409/3a5c39e0.ico",
    isAuthorized = function()
        return loggedIn() and not require("source.auth").expired(SOURCE_ID)
    end,
    apply = function(payload, cb)
        saveCookie(Setting.fromPayload(payload), cb)
    end,
}

local function startQR()
    require("ui/network/manager"):runWhenOnline(function()
        require("source.qqreader.qrlogin"):new(function(cookie) verify(cookie) end):start()
    end)
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("QQ阅读登录 Cookie"),
        fields = { { text = "", hint = _("在电脑浏览器登录 QQ阅读后粘贴 Cookie") } },
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
                title = _("QQ阅读账号"), status = status, status_on = status_on,
                callback = function() startQR() end })
        end,
    }
    if not loggedIn() then
        rows[#rows + 1] = function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "content_paste",
                title = _("粘贴 Cookie"),
                callback = function() showLogin() end })
        end
        return rows
    end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出 QQ阅读账号？"),
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
