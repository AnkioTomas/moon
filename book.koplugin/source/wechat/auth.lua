--[[--
微信读书会话：Eink 扫码拿到的 vid/accessToken 即网页会话（wr_vid/wr_skey Cookie）。

登录与续期在 ``source.wechat.eink``；这里只负责把会话拼成网页请求头，
以及带鉴权失效自动续期 + 单次重试的网页请求。
只有网页会话、没有 Eink refresh_token 的旧登录视为未登录，需要重新扫码。

网络仅异步：Request.request。

@module koplugin.book.source.wechat.auth
--]]

local Json = require("utils.json")
local logger = require("utils.log")
local Request = require("http.request")
local Header = require("http.request.header")
local Protocol = require("source.wechat.protocol")
local Eink = require("source.wechat.eink")
local Context = require("source.wechat.context")
local _ = require("gettext")

local Auth = {}

local WEB = "https://weread.qq.com"

--- 微信会话失效 errcode（对齐 weread.koplugin）。
local AUTH_ERRCODES = {
    [-2012] = true,
    [-2041] = true,
}

--- 自动续期冷却（秒）：WAF 403 / 误判的失效回包不能每个请求都打一次 /login。
local RENEW_COOLDOWN = 600
--- 上次自动续期的发起时间（不论成败）。
local renewed_at = 0

--- 合并浏览器默认请求头（UA 与 protocol.webAppId 保持一致，阅读时长上报 appId 依赖 UA）。
---@param extra table|nil
---@return table
local function browserHeaders(extra)
    return Header.merge(extra, {
        ["User-Agent"] = Protocol.USER_AGENT,
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
        ["Referer"] = WEB .. "/",
        ["Origin"] = WEB,
        ["Sec-Ch-Ua"] = '"Microsoft Edge";v="147", "Not.A/Brand";v="8", "Chromium";v="147"',
        ["Sec-Ch-Ua-Mobile"] = "?0",
        ["Sec-Ch-Ua-Platform"] = '"Windows"',
    })
end

--- 会话请求头：Eink 令牌即网页会话，Cookie 只需 wr_vid / wr_skey。
--- 旧网页登录残留的 wr_gid / wr_fp / wr_rt 属于已失效会话，不再发送。
--- 未登录（封面等匿名请求）只带浏览器头。
---@param extra table|nil
---@return table
function Auth.sessionHeaders(extra)
    local creds = Eink.credentials()
    if not creds then
        return browserHeaders(extra)
    end
    return browserHeaders(Header.merge(extra, {
        ["Cookie"] = "wr_vid=" .. creds.vid .. "; wr_skey=" .. creds.access_token .. "; wr_ql=0",
        ["X-Vid"] = creds.vid,
        ["X-Skey"] = creds.access_token,
    }))
end

--- 是否已登录：必须是 Eink 扫码会话（能续期）；旧网页会话不算。
Auth.hasSession = Eink.hasSession

--- 展示用用户标签（昵称优先，否则 user_id）。
---@return string|nil
function Auth.userLabel()
    local c = Eink.config()
    if c.user_name and c.user_name ~= "" then
        return c.user_name
    end
    if c.user_id and c.user_id ~= "" then
        return tostring(c.user_id)
    end
    return nil
end

--- 清除本地会话；wr_gid/wr_fp/wr_rt/cookie 是旧网页登录、api_key/skill_version 是已废弃
--- Skills 网关的残留，一并清掉。
function Auth.clearSession()
    Eink.save({
        cookie = "",
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
    Context.clear()
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

--- 解码 JSON 文本为 table；不是 JSON 对象返回 nil。
---@param raw string
---@return table|nil
local function decodeJson(raw)
    local ok, data = pcall(Json.decode, raw)
    return ok and type(data) == "table" and data or nil
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
        if msg:find("登录", 1, true) then
            return true
        end
    end
    local code = tonumber(http_code)
    return code == 401 or code == 403
end

--- 自动续期；冷却内不再打 /login，直接让调用方用现有令牌重试一次。
--- 单飞由 Eink.refreshAsync 负责：续期在飞时后来的请求排进同一次 /login 等结果，不能拿旧令牌立刻重试
--- （否则旧令牌必然再回失效 errcode，被当成「续期救不回来」而误判登录失效），所以在飞时不看冷却。
---@param cb fun(ok: boolean, err: string|nil, rejected: boolean|nil)
local function renewAsync(cb)
    if Eink.refreshing() then
        Eink.refreshAsync(cb)
        return
    end
    local now = os.time()
    if now - renewed_at < RENEW_COOLDOWN then
        cb(true)
        return
    end
    renewed_at = now
    Eink.refreshAsync(cb)
end

--- 当前令牌（判断请求发出后令牌是否已被别的请求续期换掉）。
---@return string|nil
local function currentToken()
    local creds = Eink.credentials()
    return creds and creds.access_token
end

---@class WechatRequestOpts
---@field headers table|nil
---@field accept string|nil
---@field content_type string|nil POST 缺省 application/json
---@field timeout number|nil 缺省 45 秒
---@field allow_redirects boolean|nil
---@field skip_auth_retry boolean|nil 不把 401/403 当会话失效（CDN 图片等）
---@field no_expire boolean|nil 续期重试后仍被拒也不判登录失效（公众号接口会因风控回失效 errcode，而书架等接口照常可用）

--- 带会话失效自动 renewal + 单次重试的 HTTP 请求。
---@param method string
---@param url string 完整 URL
---@param body string|nil
---@param opts WechatRequestOpts|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil) 失败时 raw 为 nil，res 是原始响应
---@return { cancel: fun() }|nil
local function sessionRequest(method, url, body, opts, cb)
    opts = opts or {}
    if not Auth.hasSession() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    -- 续期后重试换了请求：句柄跟着换，取消要能杀掉当前这一次。
    local cancelled, job = false, nil
    local function attempt(retried)
        local sent_token = currentToken()
        local headers = Auth.sessionHeaders(opts.headers)
        if opts.accept then
            headers["Accept"] = opts.accept
        end
        if method == "POST" then
            headers["Content-Type"] = opts.content_type or "application/json"
        end
        job = Request.request({
            url = url,
            method = method,
            body = body,
            headers = headers,
            timeout = opts.timeout or require("http.timeout").net(1.5),
            allow_redirects = opts.allow_redirects,
        }, function(res, err)
            if cancelled then return end
            if err then
                cb(nil, err, res)
                return
            end
            local code = res and res.code
            local raw = res and res.body or ""
            -- 只解一次：带 errcode 的 JSON 解出来既判失效、也经 res.json 交给调用方，免得再解一遍。
            local data = mayCarryErrCode(raw) and decodeJson(raw) or nil
            if not opts.skip_auth_retry and not retried and isAuthFailure(data, code) then
                logger.dbg("wechat auth failure", url:match("^[^?]*"), code, #raw < 200 and raw or #raw)
                -- 请求在飞期间别的请求已续期换了令牌：直接用新令牌重试，不再打 /login
                if sent_token ~= currentToken() then
                    attempt(true)
                    return
                end
                renewAsync(function(renewed, renew_err, rejected)
                    if cancelled then return end
                    if renewed then
                        attempt(true)
                    elseif rejected then
                        cb(nil, require("source.auth").expire("wechat", renew_err or _("微信读书登录已失效")), res)
                    else
                        cb(nil, renew_err or _("请求失败"), res)
                    end
                end)
                return
            end
            -- 续期重试后回包仍明确是会话失效 errcode：静默续期救不回来。
            -- 裸 401/403（WAF 拦截等）不算，免得误判暂停同步。
            if retried and not opts.skip_auth_retry and data and isAuthFailure(data, nil) then
                logger.warn("wechat auth failure after renew", url:match("^[^?]*"), #raw < 200 and raw or #raw)
                if opts.no_expire then
                    cb(nil, _("微信读书拒绝了请求，请稍后再试"), res)
                else
                    cb(nil, require("source.auth").expire("wechat", _("微信读书登录已失效")), res)
                end
                return
            end
            if not Request.ok(code) then
                cb(nil, "HTTP " .. tostring(code), res)
                return
            end
            if not opts.skip_auth_retry then require("source.auth").ok("wechat") end
            if res then res.json = data end
            cb(raw, nil, res)
        end)
    end
    attempt(false)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

--- 带会话 Cookie 的异步 GET；遇鉴权失效会自动续期后重试一次。
---@param url string 完整 URL
---@param opts WechatRequestOpts|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }|nil
function Auth.webGetAsync(url, opts, cb)
    return sessionRequest("GET", url, nil, opts, cb)
end

--- 带会话 Cookie 的异步 POST；同 webGetAsync。
---@param url string 完整 URL
---@param body string|nil 已编码的请求体
---@param opts WechatRequestOpts|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return { cancel: fun() }|nil
function Auth.webPostAsync(url, body, opts, cb)
    return sessionRequest("POST", url, body, opts, cb)
end

--- 扫码登录后补拉昵称；取不到不算失败，会话本身已可用。
---@param cb fun(user: { user_id: string, user_name: string })
---@return { cancel: fun() }|nil
function Auth.fetchUserAsync(cb)
    local vid = Eink.config().wr_vid
    return Auth.webGetAsync(WEB .. "/api/userInfo?userVid=" .. vid, nil, function(raw)
        local data = raw and decodeJson(raw)
        local name = data and type(data.name) == "string" and data.name or ""
        if name ~= "" then
            Eink.save({ user_name = name })
        end
        logger.info("weread login ok", vid, name)
        cb({ user_id = vid, user_name = name })
    end)
end

return Auth
