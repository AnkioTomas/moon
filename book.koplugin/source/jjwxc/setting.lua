--[[--
晋江源设置：登录。

晋江手机网页的登录要过数美验证，墨水屏上做不了；登录协议有两套（protocols/web.lua、protocols/app.lua），只用其中一个：
1. 网页 Cookie：远程管理里的「浏览器登录」（浏览器扩展交 Cookie），或在电脑浏览器登录后把 Cookie 请求头粘贴进来，
   先拉一次收藏页校验，通过才保存。能同步收藏、取消收藏、读已购 VIP 章。
2. App 账号：设备上直接输账号密码（新设备要手机 / 邮箱验证码），保存账号密码与 token，token 失效自动重登。
   能同步书架、读已购 VIP 章。
登录成功即切到该协议；两套都登录过时可在设置里改用哪一个。

@module koplugin.book.source.jjwxc.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "jjwxc"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.jjwxc.protocols").current() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("晋江账号"),
    cookie_title = _("晋江登录 Cookie"),
    cookie_hint = _("在电脑浏览器登录晋江手机版后粘贴 Cookie"),
    logout_text = _("确定退出晋江账号？"),
    loggedIn = loggedIn,
    -- 拉一次收藏页校验 Cookie；通过即切到网页协议。
    checkAsync = function(cookie, cb)
        require("source.jjwxc.protocols.web").favAsync(cookie, function(rows, err) cb(rows ~= nil, err) end)
    end,
    store = function(cfg, cookie) cfg.cookie, cfg.protocol = cookie, "web" end,
    clear = function(cfg) cfg.cookie, cfg.token, cfg.account, cfg.password, cfg.protocol = nil, nil, nil, nil, nil end,
}

Setting.parseCookie = CookieLogin.parse

--- 浏览器扩展交来的 payload.cookies → Cookie 请求头；只收晋江站点的 Cookie。
---@param payload table
---@return string
function Setting.fromPayload(payload)
    return CookieLogin.fromPayload(payload, "jjwxc.com")
end

--- 浏览器扩展登录（features/cookie）。
Setting.browser = {
    domain = "m.jjwxc.com",
    scope = "cookie",
    login = "https://m.jjwxc.com/my/login",
    check = "https://m.jjwxc.com/my/fav",
    icon = "https://m-static.jjwxc.net/images/wap/logo2.png",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb) CookieLogin.save(SPEC, Setting.fromPayload(payload), cb) end,
}

local showAccountLogin

---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    local Row = require("ui.themes.widgets.row")
    local rows = {
        CookieLogin.accountRow(SPEC, { callback = function() showAccountLogin() end,
            subtitle = _("也可在「远程管理」里用浏览器授权登录") }),
        require("source.review_setting").row(SOURCE_ID, plugin),
    }
    if not loggedIn() then return rows end
    local Protocols = require("source.jjwxc.protocols")
    rows[#rows + 1] = function(iw)
        local current = Protocols.current()
        return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "swap_horiz", title = _("登录协议"),
            status = current.label(), status_on = true,
            callback = function()
                local items = {}
                for _idx, protocol in ipairs(Protocols.list) do
                    items[#items + 1] = {
                        text = protocol.label() .. (protocol.available() and "" or _("（未登录）")),
                        variant = protocol == current and "primary" or "normal",
                        enabled = protocol.available(),
                        callback = function()
                            Protocols.select(protocol.id)
                            require("source.registry").reload()
                        end,
                    }
                end
                require("ui.themes.widgets.sheet"):new{ title = _("登录协议"), items = items }:show()
            end })
    end
    rows[#rows + 1] = CookieLogin.logoutRow(SPEC)
    return rows
end

---@param account string
---@param password string
---@param token string
local function saveToken(account, password, token)
    require("source.jjwxc.protocols.app").save(account, password, token)
    require("source.jjwxc.protocols").select("app")
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
end

local showLogin

--- 设备验证：选手机或邮箱收验证码，填了再登录一次。
---@param account string
---@param password string
---@param message string
local function showVerify(account, password, message)
    local Toast = require("ui.themes.widgets.toast")
    local Token = require("source.jjwxc.protocols.app")
    local checktype = "phone"
    local function send(kind)
        checktype = kind
        require("ui/network/manager"):runWhenConnected(function()
            Token.sendCodeAsync(account, kind, function(msg, err)
                Toast:new{ text = msg or err, timeout = 3 }:show()
            end)
        end)
    end
    require("ui.themes.widgets.input"):new{
        title = _("晋江设备验证"),
        fields = { { label = message, text = "", hint = _("验证码"), input_type = "number" } },
        ok_text = _("验证并登录"),
        actions = {
            { text = _("发到手机"), callback = function() send("phone") end },
            { text = _("发到邮箱"), callback = function() send("email") end },
        },
        callback = function(code)
            code = (code or ""):gsub("%s", "")
            if code == "" then
                Toast:new{ text = _("请先填写验证码"), timeout = 3 }:show()
                return
            end
            showLogin(account, password, { checktype = checktype, code = code })
        end,
    }:show()
end

--- 账号密码登录；verify 非空表示带设备验证码重试。
---@param account string
---@param password string
---@param verify { checktype: string, code: string }|nil
function showLogin(account, password, verify)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenConnected(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("晋江账号"), text = _("正在登录…"), dismissable = false,
        }
        waiting:show()
        require("source.jjwxc.protocols.app").loginAsync(account, password, verify, function(token, err, kind)
            waiting:close()
            if token then
                saveToken(account, password, token)
                Toast:new{ text = _("登录成功"), timeout = 2 }:show()
            elseif kind == "verify" then
                showVerify(account, password, err)
            else
                Toast:new{ text = err, timeout = 3 }:show()
            end
        end)
    end)
end

function showAccountLogin()
    require("ui.themes.widgets.input"):new{
        title = _("晋江账号登录"),
        fields = {
            { label = _("账号"), text = "", hint = _("笔名 / 邮箱 / 手机号") },
            { label = _("密码"), text = "", text_type = "password" },
        },
        ok_text = _("登录"),
        actions = { { text = _("用 Cookie 登录"), callback = function() CookieLogin.prompt(SPEC) end } },
        callback = function(account, password)
            account = (account or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if account == "" or (password or "") == "" then
                require("ui.themes.widgets.toast"):new{ text = _("账号或密码不能为空"), timeout = 3 }:show()
                return
            end
            showLogin(account, password)
        end,
    }:show()
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = showAccountLogin

return Setting
