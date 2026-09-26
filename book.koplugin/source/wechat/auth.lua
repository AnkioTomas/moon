--[[--
微信读书会话：Eink 扫码拿到的 vid/accessToken 即网页会话（wr_vid/wr_skey Cookie）。

登录与续期在 ``source.wechat.eink``；这里只负责把会话拼成网页请求头，
以及带鉴权失效自动续期 + 单次重试的网页请求。
只有网页会话、没有 Eink refresh_token 的旧登录视为未登录，需要重新扫码。

网络仅异步：Request.request。

@module koplugin.book.source.wechat.auth
--]]

local JSON = require("json")
local logger = require("utils.log")
local Request = require("http.request")
local Header = require("http.header")
local Protocol = require("source.wechat.protocol")
local Eink = require("source.wechat.eink")
local _ = require("gettext")

local Auth = {}

local WEB = "https://weread.qq.com"
local API = "https://i.weread.qq.com"

--- 浏览器 UA 与 protocol.webAppId 保持一致（阅读时长上报 appId 依赖 UA）。
local BROWSER_UA = Protocol.USER_AGENT

local SESSION_COOKIE_KEYS = { "wr_gid", "wr_fp", "wr_vid", "wr_skey", "wr_ql", "wr_rt" }

--- 上次续期时间戳；续期冷却内不重复打 renewal。
local last_renew_at = 0
local RENEW_COOLDOWN = 600

--- 续期进行中的等待队列（合并并发 renewal）。
local renew_waiters = nil

--- 微信会话失效 errcode（对齐 weread.koplugin）。
local AUTH_ERRCODES = {
    [-2012] = true,
    [-2041] = true,
}

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

--- 按 keys 顺序拼 Cookie；空串与缺失跳过，全空返回 nil。
---@param map table|nil
---@param keys string[]
---@return string|nil
local function cookieFrom(map, keys)
    if type(map) ~= "table" then
        return nil
    end
    local parts = {}
    for _i, k in ipairs(keys) do
        local v = map[k]
        if type(v) == "string" and v ~= "" then
            parts[#parts + 1] = k .. "=" .. v
        elseif type(v) == "number" then
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "; ")
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

--- 有效 vid：wr_vid 优先；空串在 Lua 里为真，不能让它遮蔽 user_id
---@param c table
local function vidOf(c)
    local vid = c.wr_vid
    if vid == nil or vid == "" then
        vid = c.user_id
    end
    return vid
end

--- 从配置构造会话 Cookie 字段映射。
---@param c table|nil
---@return table
local function sessionMap(c)
    local ql = c.wr_ql
    if (ql == nil or ql == "") and type(c.wr_skey) == "string" and c.wr_skey ~= "" then
        ql = "0"
    end
    return {
        wr_gid = c.wr_gid,
        wr_fp = c.wr_fp,
        wr_vid = vidOf(c),
        wr_skey = c.wr_skey,
        wr_ql = ql,
        wr_rt = c.wr_rt,
    }
end

--- Cookie 由会话字段拼装；无有效字段返回 nil。
---@return string|nil
function Auth.cookieHeader()
    return cookieFrom(sessionMap(cfg()), SESSION_COOKIE_KEYS)
end

--- 已登录请求头：Cookie + X-Vid + X-Skey。
---@param extra table|nil
---@return table
function Auth.sessionHeaders(extra)
    local c = cfg()
    local vid = vidOf(c)
    local skey = c.wr_skey
    return browserHeaders(Header.merge(extra, {
        ["Cookie"] = Auth.cookieHeader(),
        ["X-Vid"] = (vid ~= nil and vid ~= "") and tostring(vid) or nil,
        ["X-Skey"] = (type(skey) == "string" and skey ~= "") and skey or nil,
    }))
end

--- 是否已登录：必须是 Eink 扫码会话（能续期）；旧网页会话不算。
---@return boolean
function Auth.hasSession()
    return Eink.hasSession()
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

--- 清除本地会话与派生 Cookie 字段；api_key/skill_version 是已废弃 Skills 网关的残留，一并清掉。
function Auth.clearSession()
    saveCfg({
        wr_vid = "",
        wr_skey = "",
        wr_rt = "",
        wr_gid = "",
        wr_fp = "",
        wr_ql = "",
        user_id = "",
        user_name = "",
        -- 表构造器里 nil 值键不存在，pairs 看不到，必须置空串才真正清掉
        api_key = "",
        skill_version = "",
    })
    Eink.clearSession()
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

--- 会话失效探针：只有带 errcode/errmsg 的 JSON 才值得解码。
---
--- 章节正文分片、reader 页 HTML 与图片都会走同一条请求路径，动辄几百 KB 且必然不是
--- JSON；无条件 decode 一遍纯属白烧 CPU。
---@param raw string
---@return boolean
local function mayCarryErrCode(raw)
    if raw:sub(1, 1) ~= "{" then
        return false
    end
    return raw:find("errcode", 1, true) ~= nil or raw:find("errCode", 1, true) ~= nil
        or raw:find("errmsg", 1, true) ~= nil or raw:find("errMsg", 1, true) ~= nil
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

--- 判断响应是否属于会话失效（应尝试 renewal）。
---@param data table|nil
---@param http_code number|nil
---@return boolean
local function isAuthFailure(data, http_code)
    if type(data) == "table" then
        local code = tonumber(data.errcode or data.errCode)
        if code and AUTH_ERRCODES[code] then
            return true
        end
        local msg = tostring(data.errmsg or data.errMsg or "")
        if msg:find("登录", 1, true) or msg:find("超时", 1, true) then
            return true
        end
    end
    local code = tonumber(http_code)
    return code == 401 or code == 403
end

--- 尝试 renewal；冷却内跳过；并发请求合并为一次 renewal。
---@param cb fun(ok: boolean|nil, err: string|nil)
local function tryRenewAsync(cb)
    if renew_waiters then
        renew_waiters[#renew_waiters + 1] = cb
        return
    end
    if os.time() - last_renew_at < RENEW_COOLDOWN then
        -- 冷却内不再打 renewal，但仍允许上层用现有 Cookie 重试一次。
        cb(true)
        return
    end
    renew_waiters = { cb }
    Auth.renewCookieAsync(function(ok, err)
        local waiters = renew_waiters
        renew_waiters = nil
        if ok then
            last_renew_at = os.time()
        end
        for _, waiter in ipairs(waiters or {}) do
            waiter(ok, err)
        end
    end)
end

--- 带会话失效自动 renewal + 单次重试的 HTTP 请求。
---@param opts table Turbo request opts（含 skip_auth_retry）
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }|nil
local function sessionRequest(opts, cb)
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    local retried = opts._auth_retried
    opts._auth_retried = nil
    local headers = Auth.sessionHeaders(opts.headers)
    if opts.accept then
        headers["Accept"] = opts.accept
    end
    if opts.content_type then
        headers["Content-Type"] = opts.content_type
    end
    return Request.request({
        url = opts.url,
        method = opts.method or "GET",
        body = opts.body,
        headers = headers,
        timeout = opts.block_timeout or opts.timeout or 45,
        allow_redirects = opts.allow_redirects,
    }, function(res, err)
        if err then
            cb(nil, err, res)
            return
        end
        local code = res and res.code
        local raw = res and res.body or ""
        if not opts.skip_auth_retry and not retried then
            local data = mayCarryErrCode(raw) and decodeJson(raw) or nil
            if isAuthFailure(data, code) then
                tryRenewAsync(function(renewed)
                    if renewed then
                        sessionRequest(setmetatable({ _auth_retried = true }, { __index = opts }), cb)
                    else
                        cb(nil, (type(data) == "table" and (data.errmsg or data.errMsg))
                            or _("续期失败"), res)
                    end
                end)
                return
            end
        end
        if not Request.ok(code) then
            cb(nil, "HTTP " .. tostring(code), res)
            return
        end
        cb(raw, nil, res)
    end)
end

--- 带会话 Cookie 的异步 GET；遇鉴权失效会自动续期后重试一次。
---@param url string 完整 URL
---@param opts table|nil headers / accept / block_timeout / allow_redirects / skip_auth_retry
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil) 失败时 raw 为 nil，res 是原始响应
---@return { cancel: fun() }|nil
function Auth.webGetAsync(url, opts, cb)
    opts = opts or {}
    return sessionRequest({
        url = url,
        method = "GET",
        headers = opts.headers,
        accept = opts.accept,
        block_timeout = opts.block_timeout,
        allow_redirects = opts.allow_redirects,
        skip_auth_retry = opts.skip_auth_retry,
    }, cb)
end

--- Nonblocking authenticated POST.
---@param url string
---@param body string|nil
---@param opts table|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }|nil
function Auth.webPostAsync(url, body, opts, cb)
    opts = opts or {}
    return sessionRequest({
        url = url,
        method = "POST",
        body = body,
        headers = opts.headers,
        content_type = opts.content_type or "application/json",
        block_timeout = opts.block_timeout,
        skip_auth_retry = opts.skip_auth_retry,
    }, cb)
end

--- 包装回调：原始响应解码成 JSON 表再回传。
---@param cb fun(data: table|nil, err: string|nil)
---@return fun(raw: string|nil, err: string|nil)
local function jsonCallback(cb)
    return function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        cb(decodeJson(raw))
    end
end

--- Web API JSON GET；errcode 校验由 client 层的 acceptWebWire 决定。
---@param path_query string 相对 Web 站点的路径（可带 query）
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Auth.webApiGetAsync(path_query, cb)
    return Auth.webGetAsync(absUrl(WEB, path_query), nil, jsonCallback(cb))
end

--- Web API JSON POST；body 以 JSON 发出，回包解码成表。
--- 同 webApiGetAsync，errcode 校验留给 client 层。
---@param path string 相对 Web 站点的路径
---@param body_tbl table|nil 请求体，缺省发空对象
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Auth.webApiPostAsync(path, body_tbl, cb)
    return Auth.webPostAsync(absUrl(WEB, path), JSON.encode(body_tbl or {}), nil, jsonCallback(cb))
end

--- 移动端 API JSON POST（``i.weread.qq.com``）；复用 Web 会话 Cookie + X-Vid/X-Skey。
---@param path string 相对 i.weread 的路径，如 ``/shelf/delete``
---@param body_tbl table|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Auth.apiPostAsync(path, body_tbl, cb)
    return Auth.webPostAsync(absUrl(API, path), JSON.encode(body_tbl or {}), nil, jsonCallback(cb))
end

--- 扫码登录后补拉昵称；取不到不算失败，会话本身已可用。
---@param cb fun(user: { user_id: string, user_name: string })
---@return { cancel: fun() }|nil
function Auth.fetchUserAsync(cb)
    local vid = tostring(vidOf(cfg()) or "")
    return Auth.webGetAsync(WEB .. "/api/userInfo?userVid=" .. vid, nil, function(raw)
        local data = raw and decodeJson(raw)
        local name = data and type(data.name) == "string" and data.name or ""
        if name ~= "" then
            saveCfg({ user_name = name })
        end
        logger.info("weread login ok", vid, name)
        cb({ user_id = vid, user_name = name })
    end)
end

--- 续期会话：Eink refreshToken 换新 accessToken（即新 wr_skey）。
---@param cb fun(ok: boolean|nil, err: string|nil)
function Auth.renewCookieAsync(cb)
    Eink.refreshAsync(function(ok, err)
        if not ok then return cb(nil, err or _("续期失败")) end
        cb(true)
    end)
end

return Auth
