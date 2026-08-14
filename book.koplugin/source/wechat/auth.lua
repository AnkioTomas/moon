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
local _ = require("gettext")

local Auth = {}

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

--- 访问首页补齐 wr_gid / wr_fp。
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

--- 带会话头的 GET。
---@param url string
---@param opts table|nil
---@return string|nil, string|nil
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

--- 带会话头的 POST。
---@param url string
---@param body string|nil
---@param opts table|nil
---@return string|nil, string|nil
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

--- GET 并解析 JSON；可选检查微信 errcode。
---@param base string
---@param path_query string
---@param check_err boolean|nil
---@return table|nil, string|nil
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

--- GET JSON（默认 i.weread.qq.com；绝对 URL 原样）。
---@param path_query string
---@return table|nil, string|nil
function Auth.apiGet(path_query)
    return jsonGet(API, path_query, true)
end

--- POST JSON 到 i.weread.qq.com 并检查 errcode。
---@param path string
---@param body_tbl table|nil
---@return table|nil, string|nil
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

--- weread.qq.com Web API GET JSON。
---@param path_query string
---@return table|nil, string|nil
function Auth.webApiGet(path_query)
    return jsonGet(WEB, path_query, false)
end

--- weread.qq.com Web API POST JSON（不强制 errCode；Web 接口常无此字段）。
---@param path string
---@param body_tbl table|nil
---@return table|nil, string|nil
function Auth.webApiPost(path, body_tbl)
    local raw, err = Auth.webPost(absUrl(WEB, path), JSON.encode(body_tbl or {}))
    if not raw then
        return nil, err
    end
    return decodeJson(raw)
end

--- 开始扫码：getLoginUid → 本地 confirm QR；返回 { uid, qr_payload }。
---@return { uid: string, qr_payload: string }|nil, string|nil
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

--- 长连接等待扫码；失败/超时 = 二维码失效。
---@param uid string
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

--- 落盘会话 + 拉 userInfo 取昵称。
---@param info table|nil
---@return { user_id: string, user_name: string }|nil, string|nil
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

--- 刷新 Cookie（访问首页拿 Set-Cookie）。
---@return boolean|nil, string|nil
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
