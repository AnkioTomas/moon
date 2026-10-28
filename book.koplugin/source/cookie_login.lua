--[[--
Cookie 登录的公共部分：Cookie 文本 / 浏览器扩展 payload → 请求头，校验保存，粘贴窗与设置页行。

网页登录态就是 Cookie 的源（起点、QQ阅读、晋江、潇湘、长佩）都走这一套：拿到 Cookie 先经源自己的
`checkAsync` 打一次账号 / 书架接口，通过才写 `settings/<源>.lua`、`auth.ok`、重载源。
源的 setting.lua 只填一张 `CookieLoginSpec` 和自己的 `Setting.browser` URL；二维码 / 账号密码等别的进法由源自己加行。

@module koplugin.book.source.cookie_login
--]]

require("l10n").apply()
local _ = require("gettext")

---@class CookieLoginSpec
---@field id string 源 id（settings 分区 / auth 键）
---@field title string 账号行与校验窗标题，如「起点账号」
---@field cookie_title string 粘贴窗标题
---@field cookie_hint string 粘贴窗提示
---@field logout_text string 退出确认文案
---@field loggedIn fun(): boolean
---@field checkAsync fun(cookie: string, cb: fun(ok: boolean, err: string|nil)) 校验 Cookie，通过才保存
---@field store fun(cfg: table, cookie: string)|nil 写入配置；默认 cfg.cookie = cookie
---@field clear fun(cfg: table)|nil 退出时清配置；默认 cfg.cookie = nil

local CookieLogin = {}

--- RFC 6265 的 cookie-name 是 token：字母数字与 !#$%&'*+-.^_`|~。
local NAME = "^[%w!#%$%%&'%*%+%-%.%^_`|~]+$"

---@param name any
---@param value any
---@return boolean
local function validPair(name, value)
    return type(name) == "string" and name:match(NAME) ~= nil
        and type(value) == "string" and value ~= "" and not value:find("[;\r\n]")
end

---@param jar table<string, string>
---@return string
local function header(jar)
    local keys = {}
    for key in pairs(jar) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do parts[i] = key .. "=" .. jar[key] end
    return table.concat(parts, "; ")
end

--- 浏览器里复制的 Cookie 请求头（`a=1; b=2`，可带 `Cookie:` 前缀）→ 规范化请求头；格式不对的项丢弃，一项都没有返回空串。
---@param input string
---@return string
function CookieLogin.parse(input)
    local text = tostring(input):gsub("^%s*[Cc]ookie%s*:", "")
    local jar = {}
    for pair in text:gmatch("[^;]+") do
        local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if validPair(name, value) then jar[name] = value end
    end
    return header(jar)
end

--- 浏览器扩展交来的 payload.cookies → 请求头；只收 domain 本身及其子域的 Cookie。
---@param payload table
---@param domain string 站点根域，如 "qidian.com"
---@return string
function CookieLogin.fromPayload(payload, domain)
    local suffix = "%." .. domain:gsub("%.", "%%.") .. "$"
    local jar = {}
    for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
        local host = type(cookie) == "table" and type(cookie.domain) == "string"
            and cookie.domain:gsub("^%.", ""):lower()
        if host and (host == domain or host:match(suffix)) and validPair(cookie.name, cookie.value) then
            jar[cookie.name] = cookie.value
        end
    end
    return header(jar)
end

--- 校验 Cookie，通过才保存并重载源。
---@param spec CookieLoginSpec
---@param cookie string
---@param cb fun(ok: boolean, err: string|nil)
function CookieLogin.save(spec, cookie, cb)
    if cookie == "" then return cb(false, _("没有读到 Cookie")) end
    spec.checkAsync(cookie, function(ok, err)
        if not ok then return cb(false, err or _("登录失败")) end
        local settings = require("utils.settings")
        local cfg = settings.getSource(spec.id)
        if spec.store then spec.store(cfg, cookie) else cfg.cookie = cookie end
        settings.saveSource(spec.id, cfg)
        require("source.auth").ok(spec.id)
        require("source.registry").reload()
        cb(true)
    end)
end

--- 联网后带进度窗校验保存，结果 toast。
---@param spec CookieLoginSpec
---@param cookie string
function CookieLogin.verify(spec, cookie)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenConnected(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = spec.title, text = _("正在校验登录…"), dismissable = false,
        }
        waiting:show()
        CookieLogin.save(spec, cookie, function(ok, err)
            waiting:close()
            Toast:new{ text = ok and _("登录成功") or err, timeout = ok and 2 or 3 }:show()
        end)
    end)
end

--- 粘贴 Cookie 的输入窗。
---@param spec CookieLoginSpec
function CookieLogin.prompt(spec)
    require("ui.themes.widgets.input"):new{
        title = spec.cookie_title,
        fields = { { text = "", hint = spec.cookie_hint } },
        ok_text = _("登录"),
        callback = function(value)
            local cookie = CookieLogin.parse(value or "")
            if cookie == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 Cookie"), timeout = 3 }:show()
                return
            end
            CookieLogin.verify(spec, cookie)
        end,
    }:show()
end

--- `Setting.browser.isAuthorized`：登录着且没被标过期。
---@param spec CookieLoginSpec
---@return boolean
function CookieLogin.authorized(spec)
    return spec.loggedIn() and not require("source.auth").expired(spec.id)
end

--- 账号行：状态 + 点按进入 callback（默认粘贴窗）。
---@param spec CookieLoginSpec
---@param opts { callback: fun()|nil, subtitle: string|nil, off_text: string|nil }|nil
---@return fun(iw: integer): table
function CookieLogin.accountRow(spec, opts)
    opts = opts or {}
    return function(iw)
        local on = spec.loggedIn()
        return require("ui.themes.widgets.row").widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
            title = spec.title, status = on and _("已登录") or (opts.off_text or _("未登录 · 点此登录")), status_on = on,
            subtitle = not on and opts.subtitle or nil,
            callback = opts.callback or function() CookieLogin.prompt(spec) end })
    end
end

--- 「粘贴 Cookie」行：主进法是扫码 / 账号密码的源在未登录时另给的入口。
---@param spec CookieLoginSpec
---@return fun(iw: integer): table
function CookieLogin.pasteRow(spec)
    return function(iw)
        return require("ui.themes.widgets.row").widget({ width = iw, chevron = true, kind = "nav", icon = "content_paste",
            title = _("粘贴 Cookie"), callback = function() CookieLogin.prompt(spec) end })
    end
end

--- 退出登录行：确认后清配置、重载源。
---@param spec CookieLoginSpec
---@return fun(iw: integer): table
function CookieLogin.logoutRow(spec)
    return function(iw)
        return require("ui.themes.widgets.row").widget({ width = iw, chevron = false, kind = "action", icon = "logout",
            title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = spec.logout_text,
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        local settings = require("utils.settings")
                        local cfg = settings.getSource(spec.id)
                        if spec.clear then spec.clear(cfg) else cfg.cookie = nil end
                        settings.saveSource(spec.id, cfg)
                        require("ui.themes.widgets.toast"):new{ text = _("已退出登录"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end,
                }:show()
            end })
    end
end

return CookieLogin
