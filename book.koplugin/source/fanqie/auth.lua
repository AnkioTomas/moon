--[[--
番茄小说官方扫码登录。

登录协议是番茄站点的 passport Web QR 流程。请求必须关闭自动重定向：
确认扫码后，check_qrconnect 的 302 响应会先下发 sessionid，跟随重定向
会把这个 Cookie 丢掉。

@module koplugin.book.source.fanqie.auth
--]]

require("l10n").apply()
local JSON = require("json")
local Header = require("http.header")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Auth = {}

local LOGIN_PAGE = "https://fanqienovel.com/main/writer/login"
local GET_QRCODE_URL = "https://fanqienovel.com/passport/web/get_qrcode/"
local CHECK_QR_URL = "https://fanqienovel.com/passport/web/check_qrconnect/"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"

local COMMON_PARAMS = {
    passport_jssdk_version = "3.0.16",
    passport_jssdk_type = "normal",
    aid = "2503",
    language = "zh",
    account_sdk_source = "web",
}

local SET_COOKIE_ATTRS = {
    path = true, domain = true, expires = true, ["max-age"] = true,
    secure = true, httponly = true, samesite = true, priority = true,
    partitioned = true, comment = true, version = true, discard = true,
}

---@param value table
---@return table
local function copyCookies(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

---@param value any
---@return string
local function cookieHeader(value)
    local parts = {}
    for key, item in pairs(value or {}) do
        if (type(item) == "string" or type(item) == "number") and tostring(item) ~= "" then
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(item)
        end
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

--- 解析 Set-Cookie 的第一组 name=value；不把 Path/Domain 等属性当 Cookie。
---@param jar table
---@param raw any
---@return table
local function mergeSetCookie(jar, raw)
    if raw == nil or raw == "" then return jar end
    if type(raw) == "table" then
        for _, value in pairs(raw) do mergeSetCookie(jar, value) end
        return jar
    end

    -- Expires 的日期允许出现逗号，先保护它，再拆多条 Set-Cookie。
    local marker = "\1"
    local text = tostring(raw):gsub("([Ee][Xx][Pp][Ii][Rr][Ee][Ss]=[^,;]-)%,", "%1" .. marker)
    for segment in text:gmatch("[^,\r\n]+") do
        segment = segment:gsub("^%s+", ""):gsub("%s+$", ""):gsub(marker, ",")
        local key, value = segment:match("^([^=%s;]+)=([^;]*)")
        if key and value and not SET_COOKIE_ATTRS[key:lower()] then
            jar[key] = value
        end
    end
    return jar
end

---@param value table
---@return string|nil
local function csrf(value)
    local token = value and value.passport_csrf_token
    return token and tostring(token) ~= "" and tostring(token) or nil
end

---@param url string
---@param cookies table|nil
---@param csrf_token string|nil
---@param cb fun(body: string|nil, response: table|nil, err: any)
---@return table
local function rawGet(url, cookies, csrf_token, cb)
    local extra = {
        ["Accept"] = "application/json, text/javascript, text/html, */*",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
        ["Referer"] = LOGIN_PAGE,
        ["User-Agent"] = USER_AGENT,
        ["sec-fetch-dest"] = "empty",
        ["sec-fetch-mode"] = "cors",
        ["sec-fetch-site"] = "same-origin",
    }
    local cookie = cookieHeader(cookies)
    if cookie ~= "" then extra.Cookie = cookie end
    if csrf_token and csrf_token ~= "" then
        extra["x-tt-passport-csrf-token"] = csrf_token
    end
    return Request.request({
        url = url,
        method = "GET",
        headers = Header.forRequest(extra),
        timeout = 15,
        allow_redirects = false,
    }, function(response, err)
        if err then cb(nil, response, err); return end
        cb(response and response.body or "", response, nil)
    end)
end

---@param params table
---@return string
local function query(params)
    local values = {}
    for key, value in pairs(params) do values[key] = value end
    return Text.formEncode(values)
end

---@param response table|nil
---@return string|nil
local function responseError(response)
    local code = response and tonumber(response.code)
    if code and (code < 200 or code >= 400) then
        return _("番茄登录请求失败") .. " (HTTP " .. tostring(code) .. ")"
    end
end

---@param raw string|nil
---@return table|nil
local function decode(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, value = pcall(JSON.decode, raw)
    return ok and type(value) == "table" and value or nil
end

---@param cfg table|nil
---@return string|nil
function Auth.cookieHeader(cfg)
    local cookie = cookieHeader(cfg and cfg.cookies)
    return cookie ~= "" and cookie or nil
end

---@param cfg table|nil
---@return boolean
function Auth.hasSession(cfg)
    cfg = cfg or require("utils.settings").getSource("fanqie")
    local cookies = cfg.cookies
    return type(cookies) == "table"
        and type(cookies.sessionid) == "string"
        and cookies.sessionid ~= ""
end

---@param cookies table
function Auth.saveCookies(cookies)
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("fanqie")
    cfg.cookies = copyCookies(cookies)
    Settings.saveSource("fanqie", cfg)
end

function Auth.clearSession()
    Auth.saveCookies({})
end

--- 合并响应 Cookie；客户端只需要这个无副作用的原语。
---@param jar table
---@param raw any
---@return table
function Auth.mergeSetCookie(jar, raw)
    return mergeSetCookie(jar or {}, raw)
end

---@param data table
---@return table
local function resultJar(data)
    data.cookies = data.cookies or {}
    data.cookies = copyCookies(data.cookies)
    data.csrf = csrf(data.cookies) or data.csrf
    return data
end

--- 获取二维码。成功时返回 token、二维码 URL 和临时 Cookie。
---@param cb fun(result: table|nil, err: string|nil)
---@return table
function Auth.beginQrLoginAsync(cb)
    local cancelled, active = false, nil
    local function fail(message)
        if not cancelled then cb(nil, message) end
    end
    active = rawGet(LOGIN_PAGE, nil, nil, function(_body, response, err)
        if cancelled then return end
        if err then fail(tostring(err)); return end
        local login_error = responseError(response)
        if login_error then fail(login_error); return end

        local cookies = mergeSetCookie({}, Request.header(response, "Set-Cookie"))
        local params = {}
        for key, value in pairs(COMMON_PARAMS) do params[key] = value end
        params.need_logo = "true"
        params.next = LOGIN_PAGE
        active = rawGet(GET_QRCODE_URL .. "?" .. query(params), cookies, csrf(cookies),
            function(raw, qr_response, qr_err)
                if cancelled then return end
                if qr_err then fail(tostring(qr_err)); return end
                local http_error = responseError(qr_response)
                if http_error then fail(http_error); return end
                cookies = mergeSetCookie(cookies, Request.header(qr_response, "Set-Cookie"))
                local data = decode(raw)
                local item = data and data.data
                local token = type(item) == "table" and item.token
                local qr_url = type(item) == "table" and item.qrcode_index_url
                if not data or data.message ~= "success" or not token or not qr_url then
                    fail(_("番茄二维码响应无效"))
                    return
                end
                cb(resultJar({
                    token = tostring(token),
                    qr_url = tostring(qr_url),
                    cookies = cookies,
                    csrf = csrf(cookies),
                    expire_time = tonumber(item.expire_time) or 0,
                }))
            end)
    end)
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

--- 轮询一次二维码状态。UI 层负责按间隔再次调用。
---@param started table beginQrLoginAsync 的结果
---@param cb fun(result: table|nil, err: string|nil)
---@return table
function Auth.pollQrLoginAsync(started, cb)
    local cancelled = false
    local params = {}
    for key, value in pairs(COMMON_PARAMS) do params[key] = value end
    params.token = started.token
    params.next = "/"
    local job = rawGet(CHECK_QR_URL .. "?" .. query(params), started.cookies, started.csrf,
        function(raw, response, err)
            if cancelled then return end
            if err then cb(nil, tostring(err)); return end
            local code_error = responseError(response)
            if code_error then cb(nil, code_error); return end
            local cookies = mergeSetCookie(copyCookies(started.cookies),
                Request.header(response, "Set-Cookie"))
            local data = decode(raw)
            local item = data and data.data
            local status = type(item) == "table" and item.status or nil
            cb(resultJar({
                status = status and tostring(status) or "",
                cookies = cookies,
                csrf = csrf(cookies) or started.csrf,
                redirect_url = (type(item) == "table" and item.redirect_url)
                    or Request.header(response, "Location"),
                code = type(item) == "table" and item.error_code or nil,
                http_code = response and response.code,
            }))
        end)
    return { cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end }
end

---@param base string
---@param location string
---@return string
local function resolveLocation(base, location)
    if location:match("^https?://") then return location end
    local scheme, host = base:match("^(https?)://([^/]+)")
    if not scheme then return location end
    if location:sub(1, 1) == "/" then return scheme .. "://" .. host .. location end
    return (base:match("^(https?://.*/)" ) or (scheme .. "://" .. host .. "/")) .. location
end

--- 手动跟随确认后的跳转，保留每一跳的 Set-Cookie。
---@param state table poll 结果
---@param url string
---@param cb fun(cookies: table|nil, err: string|nil)
---@return table
function Auth.followRedirectAsync(state, url, cb)
    local cancelled, active, hops = false, nil, 0
    local cookies = copyCookies(state.cookies)
    local function nextHop(target)
        if cancelled then return end
        hops = hops + 1
        if hops > 5 then cb(nil, _("番茄登录重定向次数过多")); return end
        active = rawGet(target, cookies, state.csrf, function(_body, response, err)
            if cancelled then return end
            if err then cb(nil, tostring(err)); return end
            local http_error = responseError(response)
            if http_error then cb(nil, http_error); return end
            cookies = mergeSetCookie(cookies, Request.header(response, "Set-Cookie"))
            if cookies.sessionid and cookies.sessionid ~= "" then cb(cookies); return end
            local location = Request.header(response, "Location") or ""
            if location == "" then cb(nil, _("番茄登录未获取到会话")); return end
            nextHop(resolveLocation(target, tostring(location)))
        end)
    end
    nextHop(url)
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

return Auth
