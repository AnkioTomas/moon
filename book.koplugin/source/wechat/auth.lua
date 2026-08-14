--[[--
微信读书认证：Web 扫码长连接登录，会话 Cookie 自动落盘。
无 API Key、无手动粘贴 Cookie。

流程：
  GET /api/auth/getLoginUid
  → 本地 QR（confirm?uid=）
  → GET /api/auth/getLoginInfo?uid=&otp  长挂起
  → GET /api/userInfo?userVid=

网络仅异步：Request.request。

@module koplugin.book.source.wechat.auth
--]]

local JSON = require("json")
local logger = require("logger")
local Request = require("http.request")
local Header = require("http.header")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Auth = {}
local jsonGetAsync
local ensureGuestCookiesAsync

local WEB = "https://weread.qq.com"
local API = "https://i.weread.qq.com"

--- 用户提供的桌面 Edge UA（微信读书 Web）
local BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0"

local SESSION_COOKIE_KEYS = { "wr_gid", "wr_fp", "wr_vid", "wr_skey", "wr_ql", "wr_rt" }

--- 扫码会话 guest cookie（仅内存，不落盘）
local login_jar = {}

--- 合并浏览器默认请求头。
---@param extra table|nil
---@return table
local function browserHeaders(extra)
    return Header.merge(extra, {
        ["User-Agent"] = BROWSER_UA,
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
        ["Referer"] = WEB .. "/",
        ["Origin"] = WEB,
        ["Sec-Ch-Ua"] = '"Microsoft Edge";v="147", "Not.A/Brand";v="8", "Chromium";v="147"',
        ["Sec-Ch-Ua-Mobile"] = "?0",
        ["Sec-Ch-Ua-Platform"] = '"Windows"',
    })
end

--- 按 keys 顺序拼 Cookie；keys 为 nil 时：优先 wr_gid/wr_fp，再其余。
---@param map table|nil
---@param keys string[]|nil
---@return string|nil
local function cookieFrom(map, keys)
    if type(map) ~= "table" then
        return nil
    end
    local parts = {}
    --- 追加单个 Cookie 键值。
    ---@param k string
    ---@param v any
    local function add(k, v)
        if type(v) == "string" and v ~= "" then
            parts[#parts + 1] = k .. "=" .. v
        elseif type(v) == "number" then
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
    end
    if keys then
        for _i, k in ipairs(keys) do
            add(k, map[k])
        end
    else
        add("wr_gid", map.wr_gid)
        add("wr_fp", map.wr_fp)
        for k, v in pairs(map) do
            if k ~= "wr_gid" and k ~= "wr_fp" then
                add(k, v)
            end
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "; ")
end

--- 从响应头解析 Set-Cookie 为键值表。
---@param headers table|nil
---@return table<string, string>
local function parseSetCookie(headers)
    local out = {}
    if type(headers) ~= "table" then
        return out
    end
    local sc = headers["set-cookie"] or headers["Set-Cookie"]
    if type(sc) == "string" then
        sc = { sc }
    end
    if type(sc) ~= "table" then
        return out
    end
    for _i, line in ipairs(sc) do
        local k, v = line:match("^%s*([^=]+)=([^;]*)")
        if k and v then
            out[k] = v
        end
    end
    return out
end

--- URL 解码（含 + → 空格）。
---@param s string|nil
---@return string|nil
local function urlDecode(s)
    if type(s) ~= "string" then
        return s
    end
    s = s:gsub("%+", " ")
    s = s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return s
end

--- Normalize Turbo response headers for the cookie parser.
---@param res table|nil
---@return table
local function asyncHeaders(res)
    return { ["set-cookie"] = Request.header(res, "Set-Cookie") }
end

--- 把响应 Set-Cookie 合并进扫码 guest jar。
---@param headers table|nil
local function jarMerge(headers)
    for k, v in pairs(parseSetCookie(headers)) do
        login_jar[k] = v
    end
end

--- 扫码登录请求头（浏览器头 + guest Cookie）。
---@param extra table|nil
---@return table
local function loginRequestHeaders(extra)
    return browserHeaders(Header.merge(extra, {
        ["Cookie"] = cookieFrom(login_jar),
    }))
end

--- 读取微信读书源配置。
---@return table
local function cfg()
    return require("utils.settings").getSource("wechat")
end

--- 合并 patch 并落盘微信读书源配置。
---@param patch table
local function saveCfg(patch)
    local MoonSettings = require("utils.settings")
    local c = MoonSettings.getSource("wechat")
    for k, v in pairs(patch) do
        c[k] = v
    end
    MoonSettings.saveSource("wechat", c)
end

--- 从配置构造会话 Cookie 字段映射。
---@param c table|nil
---@return table
local function sessionMap(c)
    c = c or cfg()
    local ql = c.wr_ql
    if (ql == nil or ql == "") and type(c.wr_skey) == "string" and c.wr_skey ~= "" then
        ql = "0"
    end
    return {
        wr_gid = c.wr_gid,
        wr_fp = c.wr_fp,
        wr_vid = c.wr_vid or c.user_id,
        wr_skey = c.wr_skey,
        wr_ql = ql,
        wr_rt = c.wr_rt,
    }
end

--- Cookie 以字段为准拼装；旧配置仅有整段 cookie 时回退。
---@return string|nil
function Auth.cookieHeader()
    local c = cfg()
    local built = cookieFrom(sessionMap(c), SESSION_COOKIE_KEYS)
    if built then
        return built
    end
    if type(c.cookie) == "string" and c.cookie ~= "" then
        return c.cookie
    end
    return nil
end

--- 已登录请求头：Cookie + X-Vid + X-Skey。
---@param extra table|nil
---@return table
function Auth.sessionHeaders(extra)
    local c = cfg()
    local vid = c.wr_vid or c.user_id
    local skey = c.wr_skey
    return browserHeaders(Header.merge(extra, {
        ["Cookie"] = Auth.cookieHeader(),
        ["X-Vid"] = vid and tostring(vid) or nil,
        ["X-Skey"] = (type(skey) == "string" and skey ~= "") and skey or nil,
    }))
end

--- 是否已有可用会话（wr_skey 或旧 cookie 串）。
---@return boolean
function Auth.hasSession()
    local c = cfg()
    return (type(c.wr_skey) == "string" and c.wr_skey ~= "")
        or (type(c.cookie) == "string" and c.cookie:find("wr_skey=", 1, true) ~= nil)
end

--- 展示用用户标签（昵称优先，否则 user_id）。
---@return string|nil
function Auth.userLabel()
    local c = cfg()
    if c.user_name and c.user_name ~= "" then
        return c.user_name
    end
    if c.user_id and c.user_id ~= "" then
        return tostring(c.user_id)
    end
    return nil
end

--- 当前用户 vid。
---@return string|nil
function Auth.userVid()
    local c = cfg()
    local vid = c.wr_vid or c.user_id
    if type(vid) == "string" and vid ~= "" then
        return vid
    end
    if type(vid) == "number" then
        return tostring(vid)
    end
    return nil
end

--- 清除本地会话与派生 Cookie 字段。
function Auth.clearSession()
    saveCfg({
        cookie = "",
        wr_vid = "",
        wr_skey = "",
        wr_rt = "",
        wr_gid = "",
        wr_fp = "",
        wr_ql = "",
        user_id = "",
        user_name = "",
        api_key = nil,
        skill_version = nil,
    })
end

--- 字段是真相；cookie 字符串只是派生落盘（兼容旧读法）。
---@param vid string|number|nil
---@param skey string|nil
---@param rt string|nil
---@param name string|nil
---@param extras table|nil
local function applySession(vid, skey, rt, name, extras)
    extras = extras or {}
    vid = tostring(vid or "")
    skey = tostring(skey or "")
    rt = tostring(rt or "")
    local map = {
        wr_gid = extras.wr_gid or login_jar.wr_gid or "",
        wr_fp = extras.wr_fp or login_jar.wr_fp or "",
        wr_vid = vid,
        wr_skey = skey,
        wr_ql = tostring(extras.wr_ql or login_jar.wr_ql or "0"),
        wr_rt = rt,
    }
    saveCfg({
        cookie = cookieFrom(map, SESSION_COOKIE_KEYS) or "",
        wr_vid = map.wr_vid,
        wr_skey = map.wr_skey,
        wr_rt = map.wr_rt,
        wr_gid = map.wr_gid,
        wr_fp = map.wr_fp,
        wr_ql = map.wr_ql,
        user_id = vid,
        user_name = name or "",
    })
end

--- 相对路径拼到 base；已是绝对 URL 则原样返回。
---@param base string
---@param path_query string
---@return string
local function absUrl(base, path_query)
    if path_query:find("^https?://") then
        return path_query
    end
    return base .. path_query
end

--- 解码 JSON 文本为 table。
---@param raw string
---@return table|nil, string|nil
local function decodeJson(raw)
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil, _("返回非 JSON")
    end
    return data
end

--- 检查微信读书 errcode；非 0 则返回错误信息。
---@param data table
---@return table|nil, string|nil
local function checkWereadErr(data)
    local errcode = tonumber(data.errcode or data.errCode)
    if errcode and errcode ~= 0 then
        return nil, data.errmsg or data.errMsg or (_("微信读书错误 ") .. tostring(errcode))
    end
    return data
end

--- Nonblocking authenticated GET.
---@param url string
---@param opts table|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }|nil
function Auth.webGetAsync(url, opts, cb)
    opts = opts or {}
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    return Request.request({
        url = url,
        method = "GET",
        headers = Auth.sessionHeaders(opts.headers),
        timeout = opts.block_timeout or 45,
    }, function(res, err)
        if err then
            cb(nil, err, res)
        elseif not Request.ok(res and res.code) then
            cb(nil, "HTTP " .. tostring(res and res.code), res)
        else
            cb(res.body or "", nil, res)
        end
    end)
end

--- Nonblocking authenticated POST.
---@param url string
---@param body string|nil
---@param opts table|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }|nil
function Auth.webPostAsync(url, body, opts, cb)
    opts = opts or {}
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    local headers = Auth.sessionHeaders(opts.headers)
    headers["Content-Type"] = opts.content_type or "application/json"
    return Request.request({
        url = url,
        method = "POST",
        body = body,
        headers = headers,
        timeout = opts.block_timeout or 45,
    }, function(res, err)
        if err then
            cb(nil, err, res)
        elseif not Request.ok(res and res.code) then
            cb(nil, "HTTP " .. tostring(res and res.code), res)
        else
            cb(res.body or "", nil, res)
        end
    end)
end

--- Async JSON GET helper.
---@param base string
---@param path_query string
---@param check_err boolean|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
jsonGetAsync = function(base, path_query, check_err, cb)
    return Auth.webGetAsync(absUrl(base, path_query), nil, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local data, decode_err = decodeJson(raw)
        if not data then
            cb(nil, decode_err)
        elseif check_err then
            cb(checkWereadErr(data))
        else
            cb(data)
        end
    end)
end

function Auth.apiGetAsync(path_query, cb)
    return jsonGetAsync(API, path_query, true, cb)
end

function Auth.apiPostAsync(path, body_tbl, cb)
    return Auth.webPostAsync(absUrl(API, path), JSON.encode(body_tbl or {}), nil, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local data, decode_err = decodeJson(raw)
        if data then
            cb(checkWereadErr(data))
        else
            cb(nil, decode_err)
        end
    end)
end

function Auth.webApiGetAsync(path_query, cb)
    return jsonGetAsync(WEB, path_query, false, cb)
end

function Auth.webApiPostAsync(path, body_tbl, cb)
    return Auth.webPostAsync(absUrl(WEB, path), JSON.encode(body_tbl or {}), nil, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        cb(decodeJson(raw))
    end)
end

ensureGuestCookiesAsync = function(cb)
    login_jar = {}
    return Request.request({
        url = WEB .. "/",
        method = "GET",
        headers = browserHeaders(),
        timeout = 30,
    }, function(res, _err)
        jarMerge(asyncHeaders(res))
        if type(login_jar.wr_fp) ~= "string" or login_jar.wr_fp == "" then
            login_jar.wr_fp = tostring(math.random(100000000, 2147483647))
        end
        if type(login_jar.wr_gid) ~= "string" or login_jar.wr_gid == "" then
            login_jar.wr_gid = tostring(math.random(100000000, 999999999))
        end
        cb(true)
    end)
end

function Auth.beginQrLoginAsync(cb)
    local cancelled = false
    local first, second
    first = ensureGuestCookiesAsync(function()
        if cancelled then
            return
        end
        second = Request.request({
            url = WEB .. "/api/auth/getLoginUid",
            method = "GET",
            headers = loginRequestHeaders(),
            timeout = 30,
        }, function(res, err)
            if cancelled then
                return
            end
            jarMerge(asyncHeaders(res))
            if err then
                cb(nil, err)
                return
            end
            if not Request.ok(res and res.code) then
                cb(nil, _("获取登录 uid 失败"))
                return
            end
            local data, decode_err = decodeJson(res.body or "")
            if not data or not data.uid then
                cb(nil, decode_err or _("获取登录 uid 失败"))
                return
            end
            local uid = tostring(data.uid)
            cb({ uid = uid, qr_payload = WEB .. "/web/confirm?pf=2&uid=" .. uid })
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if first then first.cancel() end
            if second then second.cancel() end
        end,
    }
end

function Auth.waitQrLoginAsync(uid, cb)
    if not uid or uid == "" then
        cb(nil, _("无效 uid"), "error")
        return { cancel = function() end }
    end
    local cancelled = false
    local deadline = os.time() + 90
    local request_job
    local url = WEB .. "/api/auth/getLoginInfo?uid=" .. tostring(uid) .. "&otp"
    local function poll()
        if cancelled then
            return
        end
        request_job = Request.request({
            url = url,
            method = "GET",
            headers = loginRequestHeaders(),
            timeout = math.max(1, math.min(20, deadline - os.time())),
        }, function(res, err)
            if cancelled then
                return
            end
            if err and os.time() < deadline then
                -- 网络错误：延迟 3 秒再重试，避免轰炸服务器
                UIManager:scheduleIn(3, poll)
                return
            end
            if err or not Request.ok(res and res.code) then
                cb(nil, err or _("二维码已失效，请重新登录"), "error")
                return
            end
            jarMerge(asyncHeaders(res))
            local data, decode_err = decodeJson(res.body or "")
            if not data then
                cb(nil, decode_err or _("长连接等待返回异常"), "error")
                return
            end
            if data.succeed ~= true and data.logicCode ~= "LOGIN_SUCCESS" then
                cb(nil, data.errmsg or _("二维码已失效，请重新登录"), "error")
                return
            end
            local headers = asyncHeaders(res)
            local set = parseSetCookie(headers)
            local vid = set.wr_vid or data.webLoginVid or data.vid
            local skey = set.wr_skey or data.accessToken
            local rt = data.refreshToken or urlDecode(set.wr_rt or "")
            if not vid or not skey or tostring(skey) == "" then
                cb(nil, _("登录未拿到会话密钥"), "error")
                return
            end
            cb({
                vid = tostring(vid),
                accessToken = tostring(skey),
                refreshToken = tostring(rt or ""),
                wr_ql = set.wr_ql or "0",
                wr_gid = login_jar.wr_gid,
                wr_fp = login_jar.wr_fp,
            }, nil, "ok")
        end)
    end
    poll()
    return {
        cancel = function()
            cancelled = true
            if request_job then request_job.cancel() end
        end,
    }
end

function Auth.completeQrLoginAsync(info, cb)
    if type(info) ~= "table" then
        cb(nil, _("无登录信息"))
        return nil
    end
    local vid = tostring(info.vid or "")
    local skey = tostring(info.accessToken or info.skey or "")
    local rt = tostring(info.refreshToken or "")
    if vid == "" or skey == "" then
        cb(nil, _("无登录信息"))
        return nil
    end
    local extras = { wr_gid = info.wr_gid, wr_fp = info.wr_fp, wr_ql = info.wr_ql }
    applySession(vid, skey, rt, "", extras)
    login_jar = {}
    return Auth.webGetAsync(WEB .. "/api/userInfo?userVid=" .. vid, nil, function(raw)
        local name = ""
        if raw then
            local data = decodeJson(raw)
            if data and type(data.name) == "string" then
                name = data.name
                applySession(vid, skey, rt, name, extras)
            end
        end
        logger.info("weread login ok", vid, name)
        cb({ user_id = vid, user_name = name })
    end)
end

function Auth.renewCookieAsync(cb)
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    return Request.request({
        url = WEB .. "/",
        method = "HEAD",
        headers = Auth.sessionHeaders(),
        timeout = 20,
    }, function(res, err)
        if err then
            cb(nil, err)
            return
        end
        local set = parseSetCookie(asyncHeaders(res))
        if set.wr_skey or set.wr_rt then
            local c = cfg()
            applySession(
                set.wr_vid or c.wr_vid or c.user_id,
                set.wr_skey or c.wr_skey,
                urlDecode(set.wr_rt or c.wr_rt or ""),
                c.user_name,
                {
                    wr_gid = set.wr_gid or c.wr_gid,
                    wr_fp = set.wr_fp or c.wr_fp,
                    wr_ql = set.wr_ql or c.wr_ql,
                }
            )
            cb(true)
        elseif not Request.ok(res and res.code) then
            cb(nil, _("续期失败 HTTP ") .. tostring(res and res.code))
        else
            cb(true)
        end
    end)
end

return Auth
