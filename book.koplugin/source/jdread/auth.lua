--[[--
京东账号扫码登录：二维码 PNG → 状态轮询 → ticket 换取 .jd.com 会话。

@module koplugin.book.source.jdread.auth
--]]

local JSON = require("json")
local Request = require("http.request")
local Image = require("utils.image")
local Text = require("utils.text")
local _ = require("gettext")
local logger = require("utils.log")

local Auth = {}

local LOGIN_PAGE = "https://passport.jd.com/new/login.aspx?ReturnUrl=https%3A%2F%2Fe.m.jd.com%2F"
local HOME = "https://e.m.jd.com/"
local LOGIN_UA = Request.randomUA()
local QR_COOKIE_KEYS = { "QRCodeKey", "wlfstk_smdl", "guid" }
-- 真正代表已登录的 cookie：至少要有其一才算成功，其余埋点 cookie 不算。
local LOGIN_COOKIE_KEYS = { "thor", "pt_key", "pin", "pt_pin" }
local MAX_HOPS = 5
local qr_seq = 0
local qr_file

-- qrCodeTicketValidation 的 returnCode 语义，取自官方 login.qrcode.2024.js。
local TICKET_ERRORS = {
    [58] = "二维码已失效，请重新登录",
    [59] = "二维码已失效，请重新登录",
    [60] = "京东登录失败",
    [70] = "京东登录失败",
    [80] = "京东判定本次扫码存在风险，请稍后重试",
}

---@return table
local function cfg()
    return require("utils.settings").getSource("jdread")
end

---@param patch table
local function saveCfg(patch)
    local Settings = require("utils.settings")
    local current = Settings.getSource("jdread")
    for key, value in pairs(patch) do current[key] = value end
    Settings.saveSource("jdread", current)
end

--- 全部 Set-Cookie 行：优先 Request.headerAll（Turbo 多值 / 合并行都拆好），否则退回单值读取。
---@param res table|nil
---@return string[]
local function setCookieLines(res)
    if Request.headerAll then return Request.headerAll(res, "Set-Cookie") end
    local values = Request.header(res, "Set-Cookie")
    local out = {}
    local split = require("http.request.header").splitSetCookie
    for _idx, value in ipairs(type(values) == "table" and values or { values }) do
        for _j, line in ipairs(split(value)) do out[#out + 1] = line end
    end
    return out
end

--- 合并响应里的每一条 Set-Cookie；返回本跳设置的 cookie 名（只名字，不含值，供日志）。
---@param jar table
---@param res table|nil
---@return string[] names
local function mergeCookies(jar, res)
    local names = {}
    for _idx, line in ipairs(setCookieLines(res)) do
        local key, value = line:match("^%s*([^=;]+)=([^;]*)")
        if key then
            key = key:match("^%s*(.-)%s*$")
            if value == "" or value == "deleted" then jar[key] = nil else jar[key] = value end
            names[#names + 1] = key
        end
    end
    return names
end

---@param jar table
---@return string|nil
local function cookieHeader(jar)
    local keys = {}
    for key, value in pairs(jar) do
        if type(value) == "string" and value ~= "" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    if #keys == 0 then return nil end
    local parts = {}
    for _idx, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. jar[key] end
    return table.concat(parts, "; ")
end

---@param jar table
---@return table
local function browserHeaders(jar)
    return {
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Cookie"] = cookieHeader(jar),
        ["Referer"] = LOGIN_PAGE,
        ["User-Agent"] = LOGIN_UA,
    }
end

---@return string
local function timestamp()
    return tostring(os.time() * 1000 + math.random(0, 999))
end

local function clearQrFile()
    if qr_file then
        os.remove(qr_file)
        qr_file = nil
    end
end

--- 每次换新文件名：同一路径会被位图缓存成上一张已作废的码。
---@return string
local function nextQrFile()
    clearQrFile()
    local Paths = require("utils.paths")
    Paths.ensureLayout("jdread")
    qr_seq = qr_seq + 1
    qr_file = Paths.imageDir("jdread") .. "/login-qr-" .. qr_seq .. ".png"
    return qr_file
end

local function dropQrCookies(jar)
    for _idx, key in ipairs(QR_COOKIE_KEYS) do
        jar[key] = nil
    end
end

---@param base string
---@param loc string|nil
---@return string|nil
local function absUrl(base, loc)
    if type(loc) ~= "string" or loc == "" then return nil end
    if loc:find("^https?://") then return loc end
    -- 协议相对地址 //host/path：沿用当前协议，不能拼在当前 host 后面。
    if loc:sub(1, 2) == "//" then
        local scheme = type(base) == "string" and base:match("^(https?):") or "https"
        return scheme .. ":" .. loc
    end
    local origin = type(base) == "string" and base:match("^(https?://[^/]+)")
    if not origin then return nil end
    if loc:sub(1, 1) == "/" then return origin .. loc end
    return origin .. "/" .. loc
end

---@return boolean
function Auth.hasSession()
    local cookie = cfg().cookie
    return type(cookie) == "string" and cookie ~= ""
end

---@return string|nil
function Auth.userLabel()
    local current = cfg()
    if type(current.user_name) == "string" and current.user_name ~= "" then
        return current.user_name
    end
    return nil
end

--- 清除账号会话，保留设备 UUID。
function Auth.clearSession()
    saveCfg({ cookie = "", user_name = "" })
end

--- 获取二维码 PNG 及轮询所需 Cookie。
--- jar 归本次登录独占：check 要求 token 与同一张码的 wlfstk_smdl/QRCodeKey 配对，串用即 257“参数异常”。
---@param cb fun(data: { qr_path: string, token: string, jar: table }|nil, err: string|nil)
---@return { cancel: fun() }
function Auth.beginQrLoginAsync(cb)
    local jar = {}
    local path = nextQrFile()
    local cancelled = false
    local url = "https://qr.m.jd.com/show?" .. Text.formEncode({
        appid = 133,
        size = 147,
        t = timestamp(),
    })
    local job = Request.get(url, {
        headers = browserHeaders(jar),
        timeout = require("http.timeout").net(1),
    }, function(body, err, res)
        if cancelled then return end
        mergeCookies(jar, res)
        local token = jar.wlfstk_smdl
        if not body or Image.ext(body) ~= ".png"
            or type(token) ~= "string" or token == "" then
            cb(nil, err or _("获取京东登录二维码失败"))
            return
        end
        local file, open_err = io.open(path, "wb")
        if not file then cb(nil, open_err or _("无法保存登录二维码")); return end
        local wrote, write_err = file:write(body)
        local closed = file:close()
        if not wrote or not closed then
            clearQrFile()
            cb(nil, write_err or _("无法保存登录二维码"))
            return
        end
        cb({ qr_path = path, token = token, jar = jar })
    end)
    return { cancel = function()
            cancelled = true
            job.cancel()
            clearQrFile()
        end }
end

--- 轮询京东扫码状态，最多等待 120 秒。
---@param login { token: string, jar: table } beginQrLoginAsync 的结果
---@param cb fun(data: { ticket: string, jar: table }|nil, err: string|nil, status: string)
---@return { cancel: fun() }
function Auth.waitQrLoginAsync(login, cb)
    local token, jar = login.token, login.jar
    local cancelled = false
    local deadline = os.time() + 120
    local request_job

    local function poll()
        if cancelled then return end
        local callback = "jQuery" .. tostring(math.random(1000000, 9999999))
        local url = "https://qr.m.jd.com/check?" .. Text.formEncode({
            callback = callback,
            appid = 133,
            token = token,
            _ = timestamp(),
        })
        request_job = Request.get(url, {
            headers = browserHeaders(jar),
            timeout = require("http.timeout").net(2 / 3),
        }, function(raw, err, res)
            if cancelled then return end
            mergeCookies(jar, res)
            if (not raw or err) and os.time() < deadline then
                require("ui/uimanager"):scheduleIn(3, poll)
                return
            end
            if not raw then
                clearQrFile()
                cb(nil, err or _("二维码已失效，请重新登录"), "error")
                return
            end
            local payload = raw:match("^%s*" .. callback .. "%s*%((.*)%)%s*;?%s*$")
            local ok, data = pcall(JSON.decode, payload or "")
            if not ok or type(data) ~= "table" then
                clearQrFile()
                cb(nil, _("京东扫码状态无效"), "error")
                return
            end
            local code = tonumber(data.code)
            if code == 200 and type(data.ticket) == "string" and data.ticket ~= "" then
                cb({ ticket = data.ticket, jar = jar }, nil, "ok")
            elseif (code == 201 or code == 202) and os.time() < deadline then
                require("ui/uimanager"):scheduleIn(3, poll)
            else
                clearQrFile()
                cb(nil, data.msg or _("二维码已失效，请重新登录"), "error")
            end
        end)
    end
    poll()
    return { cancel = function()
            cancelled = true
            if request_job then request_job.cancel() end
            clearQrFile()
        end }
end

---@param jar table
---@return boolean
local function hasLoginCookie(jar)
    for _idx, key in ipairs(LOGIN_COOKIE_KEYS) do
        local value = jar[key]
        if type(value) == "string" and value ~= "" then return true end
    end
    return false
end
Auth._hasLoginCookie = hasLoginCookie

--- jar 里的 cookie 名（排序），日志用，绝不含值。
---@param jar table
---@return string
local function cookieNames(jar)
    local keys = {}
    for key in pairs(jar) do keys[#keys + 1] = key end
    table.sort(keys)
    return table.concat(keys, ",")
end

--- 去掉 query / fragment（ticket 等敏感参数在 query 里）。
---@param url string|nil
---@return string
local function safeUrl(url)
    if type(url) ~= "string" then return "-" end
    return (url:gsub("[?#].*$", ""))
end

--- 200 中转页里的 JS / meta 跳转目标。
---@param body string|nil
---@return string|nil
local function pageRedirect(body)
    if type(body) ~= "string" or body == "" then return nil end
    local target = body:match("[Hh][Tt][Tt][Pp]%-[Ee][Qq][Uu][Ii][Vv]%s*=%s*[\"']?[Rr]efresh[\"']?[^>]-[Uu][Rr][Ll]%s*=%s*([^\"'>%s]+)")
        or body:match("location%.replace%s*%(%s*[\"']([^\"']+)[\"']")
        or body:match("location%.href%s*=%s*[\"']([^\"']+)[\"']")
        or body:match("location%s*=%s*[\"']([^\"']+)[\"']")
    if target then target = target:gsub("&amp;", "&") end
    return target
end
Auth._pageRedirect = pageRedirect
Auth._absUrl = absUrl

--- 使用扫码 ticket 换取登录 Cookie 并原子保存源配置。
--- 成功 = jar 里出现 thor/pt_key/pin 等登录 cookie；校验之后跟 Location / data.url / 页面跳转最多 5 跳，
--- 都没拿到再补一跳 e.m.jd.com。每一步只记 cookie 名，不记值。
---@param info { ticket: string, jar: table } waitQrLoginAsync 的结果
---@param cb fun(user: { user_name: string }|nil, err: string|nil)
---@return { cancel: fun() }
function Auth.completeQrLoginAsync(info, cb)
    local jar = info.jar
    local cancelled = false
    local job
    local hops = 0
    local visited = {}

    ---@param step string
    ---@param res table|nil
    ---@param names string[]
    ---@param extra string|nil
    local function trace(step, url, res, names, extra)
        logger.dbg("jdread login", step, safeUrl(url), "status", res and res.code or "-",
            "set-cookie", #names, "names", table.concat(names, ","),
            "location", safeUrl(Request.header(res, "Location")), extra or "")
    end

    local function persist()
        dropQrCookies(jar)
        if not hasLoginCookie(jar) then
            logger.warn("jdread login no session cookie", "hops", hops, "jar", cookieNames(jar))
            clearQrFile()
            -- 中转页跳 aq.jd.com/certified：京东风控要求账号安全验证，扫码这条路拿不到会话。
            local certified = false
            for url in pairs(visited) do
                if url:find("^https?://aq%.jd%.com/certified") then certified = true end
            end
            cb(nil, certified and _("京东要求先完成账号安全验证，请在京东 App 或网页登录一次完成验证后再扫码")
                or _("登录未拿到会话 Cookie"))
            return
        end
        local cookie = cookieHeader(jar)
        local Settings = require("utils.settings")
        local current = Settings.getSource("jdread")
        local name = Text.urlDecode(jar.unick or jar.pin or "") or ""
        current.cookie = cookie
        current.uuid = current.uuid ~= nil and current.uuid ~= ""
            and current.uuid or ("h5" .. require("ffi/sha2").md5(require("utils.device_id").ensure()))
        current.user_name = name
        Settings.saveSource("jdread", current)
        logger.info("jdread login ok", "hops", hops, "jar", cookieNames(jar))
        clearQrFile()
        cb({ user_name = name })
    end

    local follow
    --- 下一跳：Location → 页面跳转 → 兜底首页；都用过了返回 nil。
    local function nextUrl(base, body, res)
        if hops >= MAX_HOPS then return nil end
        -- 候选可能为 nil，不能用 ipairs。
        local candidates = {
            absUrl(base, Request.header(res, "Location")) or false,
            absUrl(base, pageRedirect(body)) or false,
            HOME,
        }
        for i = 1, #candidates do
            local url = candidates[i]
            if url and not visited[url] then return url end
        end
        return nil
    end

    --- 不走 Request.allow_redirects，302 的 Set-Cookie 在 res 里。
    follow = function(url)
        hops = hops + 1
        visited[url] = true
        job = Request.get(url, {
            headers = browserHeaders(jar),
            timeout = require("http.timeout").net(1),
        }, function(body, _err, res)
            if cancelled then return end
            local names = mergeCookies(jar, res)
            trace("hop " .. hops, url, res, names)
            if hasLoginCookie(jar) then
                persist()
                return
            end
            local next_url = nextUrl(url, body, res)
            if next_url then
                follow(next_url)
                return
            end
            persist()
        end)
    end

    local url = "https://passport.jd.com/uc/qrCodeTicketValidation?" .. Text.formEncode({
        t = info.ticket,
        ReturnUrl = HOME,
    })
    job = Request.get(url, {
        headers = browserHeaders(jar),
        timeout = require("http.timeout").net(1),
    }, function(raw, err, res)
        if cancelled then return end
        local names = mergeCookies(jar, res)
        local ok, data = pcall(JSON.decode, raw or "")
        local code = ok and type(data) == "table" and tonumber(data.returnCode) or nil
        trace("validate", url, res, names, "returnCode " .. tostring(code)
            .. " url " .. safeUrl(type(data) == "table" and data.url or nil))
        if not raw then
            logger.warn("jdread login validate failed", tostring(err))
            clearQrFile()
            cb(nil, err or _("京东登录校验失败"))
            return
        end
        if code ~= 0 then
            logger.warn("jdread login validate rejected", "returnCode", tostring(code))
            clearQrFile()
            local msg = _(TICKET_ERRORS[code] or "京东登录校验失败")
            cb(nil, code and (msg .. " (" .. code .. ")") or msg)
            return
        end
        if hasLoginCookie(jar) then
            persist()
            return
        end
        local hop = data.url
        follow(absUrl(url, type(hop) == "string" and hop ~= "" and hop or nil) or HOME)
    end)
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
            clearQrFile()
        end }
end

--- Validate and save a browser-captured JD session without replacing the QR login flow.
---@param payload table
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function Auth.importBrowserAsync(payload, cb)
    local cookies = type(payload.cookies) == "table" and payload.cookies or {}
    local jar = {}
    for _idx, cookie in ipairs(cookies) do
        if type(cookie) == "table" then
            local domain = type(cookie.domain) == "string" and cookie.domain:gsub("^%.", ""):lower()
            local name, value = cookie.name, cookie.value
            local jd_domain = domain == "jd.com" or domain == "e.m.jd.com"
            if jd_domain and type(name) == "string" and name:match("^[%w_%-]+$")
                and type(value) == "string" and value ~= ""
                and not value:find("[;\r\n]") then
                jar[name] = value
            end
        end
    end
    dropQrCookies(jar)
    if not hasLoginCookie(jar) then
        cb(false, _("登录未拿到会话 Cookie"))
        return nil
    end

    local current = cfg()
    local uuid = current.uuid
    if type(uuid) ~= "string" or uuid == "" then
        uuid = "h5" .. require("ffi/sha2").md5(require("utils.device_id").ensure())
    end
    local cookie = cookieHeader(jar)
    local client = require("source.jdread.client"):new{ cookie = cookie, uuid = uuid }
    return client:apiGetAsync("/jdread/api/bookshelf/sort", nil, function(wire, err)
        if not wire then
            cb(false, err or _("京东登录校验失败"))
            return
        end
        current = require("utils.settings").getSource("jdread")
        current.cookie = cookie
        current.uuid = uuid
        current.user_name = Text.urlDecode(jar.unick or jar.pin or jar.pt_pin or "") or ""
        require("utils.settings").saveSource("jdread", current)
        cb(true)
    end)
end

return Auth
