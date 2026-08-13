--[[--
微信读书认证：Web 扫码长连接登录，会话 Cookie 自动落盘。
无 API Key、无手动粘贴 Cookie。

流程：
  GET /api/auth/getLoginUid
  → 本地 QR（confirm?uid=）
  → GET /api/auth/getLoginInfo?uid=&otp  长挂起
  → GET /api/userInfo?userVid=

@module koplugin.book.source.wechat.auth
--]]

local JSON = require("json")
local ltn12 = require("ltn12")
local logger = require("logger")
local Request = require("http.request")
local Header = require("http.header")
local MoonSettings = require("moon.settings")
local _ = require("gettext")

local Auth = {}

local WEB = "https://weread.qq.com"
local API = "https://i.weread.qq.com"

--- 用户提供的桌面 Edge UA（微信读书 Web）
local BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0"

local SESSION_COOKIE_KEYS = { "wr_gid", "wr_fp", "wr_vid", "wr_skey", "wr_ql", "wr_rt" }

--- 扫码会话 guest cookie（仅内存，不落盘）
local login_jar = {}

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

--- 按 keys 顺序拼 Cookie；keys 为 nil 时：优先 wr_gid/wr_fp，再其余
local function cookieFrom(map, keys)
    if type(map) ~= "table" then
        return nil
    end
    local parts = {}
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

local function jarMerge(headers)
    for k, v in pairs(parseSetCookie(headers)) do
        login_jar[k] = v
    end
end

local function loginRequestHeaders(extra)
    return browserHeaders(Header.merge(extra, {
        ["Cookie"] = cookieFrom(login_jar),
    }))
end

--- 访问首页补齐 wr_gid / wr_fp
local function ensureGuestCookies()
    login_jar = {}
    local chunks = {}
    local _code, headers = Request.send({
        url = WEB .. "/",
        method = "GET",
        headers = Header.forRequest(browserHeaders()),
        sink = ltn12.sink.table(chunks),
    }, 15, 30)
    jarMerge(headers)
    if type(login_jar.wr_fp) ~= "string" or login_jar.wr_fp == "" then
        login_jar.wr_fp = tostring(math.random(100000000, 2147483647))
    end
    if type(login_jar.wr_gid) ~= "string" or login_jar.wr_gid == "" then
        login_jar.wr_gid = tostring(math.random(100000000, 999999999))
    end
end

local function cfg()
    return MoonSettings.getSource("wechat") or {}
end

local function saveCfg(patch)
    local c = cfg()
    for k, v in pairs(patch) do
        c[k] = v
    end
    MoonSettings.saveSource("wechat", c)
end

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

--- Cookie 以字段为准拼装；旧配置仅有整段 cookie 时回退
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

--- 已登录请求头：Cookie + X-Vid + X-Skey
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

function Auth.hasSession()
    local c = cfg()
    return (type(c.wr_skey) == "string" and c.wr_skey ~= "")
        or (type(c.cookie) == "string" and c.cookie:find("wr_skey=", 1, true) ~= nil)
end

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

--- 字段是真相；cookie 字符串只是派生落盘（兼容旧读法）
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

local function absUrl(base, path_query)
    if path_query:find("^https?://") then
        return path_query
    end
    return base .. path_query
end

local function decodeJson(raw)
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil, _("返回非 JSON")
    end
    return data
end

local function checkWereadErr(data)
    local errcode = tonumber(data.errcode or data.errCode)
    if errcode and errcode ~= 0 then
        return nil, data.errmsg or data.errMsg or (_("微信读书错误 ") .. tostring(errcode))
    end
    return data
end

--- 带会话头的 GET
function Auth.webGet(url, opts)
    opts = opts or {}
    if not Auth.hasSession() then
        return nil, _("请先扫码登录微信读书")
    end
    return Request.get(url, {
        headers = Auth.sessionHeaders(opts.headers),
        accept = opts.accept or "application/json",
        timeout = opts.timeout or 15,
        block_timeout = opts.block_timeout or 45,
    })
end

function Auth.webPost(url, body, opts)
    opts = opts or {}
    if not Auth.hasSession() then
        return nil, _("请先扫码登录微信读书")
    end
    return Request.post(url, body, {
        headers = Auth.sessionHeaders(opts.headers),
        content_type = opts.content_type or "application/json",
        accept = opts.accept or "application/json",
        timeout = opts.timeout or 15,
        block_timeout = opts.block_timeout or 45,
    })
end

local function jsonGet(base, path_query, check_err)
    local raw, err = Auth.webGet(absUrl(base, path_query))
    if not raw then
        return nil, err
    end
    local data, e = decodeJson(raw)
    if not data then
        return nil, e
    end
    if check_err then
        return checkWereadErr(data)
    end
    return data
end

--- GET JSON（默认 i.weread.qq.com；绝对 URL 原样）
function Auth.apiGet(path_query)
    return jsonGet(API, path_query, true)
end

function Auth.apiPost(path, body_tbl)
    local raw, err = Auth.webPost(absUrl(API, path), JSON.encode(body_tbl or {}))
    if not raw then
        return nil, err
    end
    local data, e = decodeJson(raw)
    if not data then
        return nil, e
    end
    return checkWereadErr(data)
end

--- weread.qq.com Web API GET JSON
function Auth.webApiGet(path_query)
    return jsonGet(WEB, path_query, false)
end

--- weread.qq.com Web API POST JSON（不强制 errCode；Web 接口常无此字段）
function Auth.webApiPost(path, body_tbl)
    local raw, err = Auth.webPost(absUrl(WEB, path), JSON.encode(body_tbl or {}))
    if not raw then
        return nil, err
    end
    return decodeJson(raw)
end

--- 开始扫码：getLoginUid → 本地 confirm QR；返回 { uid, qr_payload }
function Auth.beginQrLogin()
    ensureGuestCookies()

    local chunks = {}
    local http_code, headers, err = Request.send({
        url = WEB .. "/api/auth/getLoginUid",
        method = "GET",
        headers = Header.forRequest(loginRequestHeaders(), "*/*"),
        sink = ltn12.sink.table(chunks),
    }, 15, 30)
    jarMerge(headers)
    if err then
        return nil, err
    end
    if not Request.ok(http_code) then
        return nil, _("获取登录 uid 失败")
    end
    local data, e = decodeJson(table.concat(chunks))
    if not data or not data.uid then
        return nil, e or _("获取登录 uid 失败")
    end
    local uid = tostring(data.uid)
    return { uid = uid, qr_payload = WEB .. "/web/confirm?pf=2&uid=" .. uid }
end

--- 长连接等待扫码；失败/超时 = 二维码失效
---@return table|nil info, string|nil err, string|nil status ok|error
function Auth.waitQrLogin(uid)
    if not uid or uid == "" then
        return nil, _("无效 uid"), "error"
    end
    local url = WEB .. "/api/auth/getLoginInfo?uid=" .. tostring(uid) .. "&otp"
    local chunks = {}
    local http_code, headers, err = Request.send({
        url = url,
        method = "GET",
        headers = Header.forRequest(loginRequestHeaders(), "*/*"),
        sink = ltn12.sink.table(chunks),
    }, 60, 90)
    if err then
        return nil, err or _("二维码已失效，请重新登录"), "error"
    end
    if not Request.ok(http_code) then
        return nil, _("二维码已失效，请重新登录"), "error"
    end
    jarMerge(headers)
    local data, e = decodeJson(table.concat(chunks))
    if not data then
        return nil, e or _("长连接等待返回异常"), "error"
    end
    if data.succeed ~= true and data.logicCode ~= "LOGIN_SUCCESS" then
        return nil, data.errmsg or _("二维码已失效，请重新登录"), "error"
    end
    local set = parseSetCookie(headers or {})
    local vid = set.wr_vid or data.webLoginVid or data.vid
    local skey = set.wr_skey or data.accessToken
    local rt = data.refreshToken or urlDecode(set.wr_rt or "")
    if not vid or not skey or tostring(skey) == "" then
        return nil, _("登录未拿到会话密钥"), "error"
    end
    return {
        vid = tostring(vid),
        accessToken = tostring(skey),
        refreshToken = tostring(rt or ""),
        wr_ql = set.wr_ql or "0",
        wr_gid = login_jar.wr_gid,
        wr_fp = login_jar.wr_fp,
    }, nil, "ok"
end

--- 落盘会话 + 拉 userInfo 取昵称
function Auth.completeQrLogin(info)
    if type(info) ~= "table" then
        return nil, _("无登录信息")
    end
    local vid = tostring(info.vid or "")
    local skey = tostring(info.accessToken or info.skey or "")
    local rt = tostring(info.refreshToken or "")
    if vid == "" or skey == "" then
        return nil, _("无登录信息")
    end
    local extras = {
        wr_gid = info.wr_gid,
        wr_fp = info.wr_fp,
        wr_ql = info.wr_ql,
    }
    applySession(vid, skey, rt, "", extras)
    login_jar = {}

    local name = ""
    local raw = Auth.webGet(WEB .. "/api/userInfo?userVid=" .. vid)
    if raw then
        local data = decodeJson(raw)
        if data and type(data.name) == "string" then
            name = data.name
            applySession(vid, skey, rt, name, extras)
        end
    end
    logger.info("weread login ok", vid, name)
    return {
        user_id = vid,
        user_name = name,
    }
end

--- 刷新 Cookie（访问首页拿 Set-Cookie）
function Auth.renewCookie()
    if not Auth.hasSession() then
        return nil, _("请先扫码登录微信读书")
    end
    local chunks = {}
    local code, headers, err = Request.send({
        url = WEB .. "/",
        method = "HEAD",
        headers = Header.forRequest(Auth.sessionHeaders()),
        sink = ltn12.sink.table(chunks),
    }, 10, 20)
    if err then
        return nil, err
    end
    local set = parseSetCookie(headers or {})
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
        return true
    end
    if not Request.ok(code) then
        return nil, _("续期失败 HTTP ") .. tostring(code)
    end
    return true
end

return Auth
