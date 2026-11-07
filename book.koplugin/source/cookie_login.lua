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
---@field checkAsync fun(cookie: string, cb: fun(ok: boolean, err: string|nil, account: table|nil)): HttpJob|nil 校验 Cookie，通过才保存
---@field commit fun(cookie: string, account: table|nil, cb: fun(ok: boolean, err: string|nil)): HttpJob|nil 可选的源级账号边界与保存
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
    local cancelled, job, pending = false, nil, true
    local check = spec.checkAsync(cookie, function(ok, err, account)
        pending = false
        if cancelled then return end
        if not ok then return cb(false, err or _("登录失败")) end
        if spec.commit then
            local committing = true
            local inner = spec.commit(cookie, account, function(saved, reason)
                committing = false
                if not cancelled then cb(saved, reason) end
            end)
            if committing then job = inner end
            return
        end
        local settings = require("utils.settings")
        local cfg = settings.getSource(spec.id)
        if spec.store then spec.store(cfg, cookie) else cfg.cookie = cookie end
        settings.saveSource(spec.id, cfg)
        require("source.auth").ok(spec.id)
        require("source.registry").reload()
        cb(true)
    end)
    if pending then job = check end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
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

--- 网页登录态失效时的操作说明。name 是远程管理「浏览器登录」列表里的源名称，url 是要重新打开的登录页。
--- paste_where 非空时附上手动复制 Cookie 的路径（「源名 → 设置里的那一行」）。
---@param name string
---@param url string
---@param paste_where string|nil
---@return string
function CookieLogin.relogin(name, url, paste_where)
    local T = require("ffi/util").template
    local steps = T(_("%1 的登录已经失效。请按顺序做完，再回到月读重新打开这本书：\n1. 用电脑浏览器打开 %2 。页面上如果已经登录，先点退出，再重新登录一次。\n2. 回到月读，依次点「设置」「系统」「连接」「远程管理」，把「远程管理服务」打开。屏幕上会出现网址和二维码。\n3. 用电脑浏览器打开这个网址，或者用电脑去扫屏幕上的二维码。月读问你允不允许，点「允许」。\n4. 网页里点「浏览器登录」。\n5. 如果网页说没有检测到浏览器扩展，点「前往 GitHub 安装 moon-cookie-storage」，按网页说明装上，然后刷新这个网页。\n6. 在列表里找到「%1」，点「继续授权」或「重新授权」。浏览器会打开官网让你登录，登录完回到这个网页，看到成功就行。"),
        name, url)
    if not paste_where then return steps end
    return steps .. "\n\n" .. T(_("不想装扩展的话，用这个办法代替上面的第 2 步到第 6 步：电脑上按第 1 步登录好，按键盘上的 F12，点「网络」，再按一次刷新。点任意一条请求，在「请求标头」里找到 Cookie，从第一个字符复制到最后一个。回到月读，依次点「设置」「书库」「账号」「%1」，把复制的内容贴进输入框，点「登录」。"), paste_where)
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

--- 退出登录行：确认后清凭证，并清掉这个源的本地书架和阅读记录。
---@param spec CookieLoginSpec
---@return fun(iw: integer): table
function CookieLogin.logoutRow(spec)
    return require("source.logout").row(spec.id, spec.logout_text, function()
        local settings = require("utils.settings")
        local cfg = settings.getSource(spec.id)
        if spec.clear then spec.clear(cfg) else cfg.cookie = nil end
        settings.saveSource(spec.id, cfg)
    end)
end

return CookieLogin
