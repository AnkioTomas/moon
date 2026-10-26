--[[--
微信读书 App 协议（手机 App 10.2.2 身份）客户端 API：扫码登录、令牌续期与 ``i.weread.qq.com`` 请求。

协议移植自 weread-omni（profile.ts / device-ua.ts / auth/qrlogin.ts / auth/token.ts / api/mobile.ts）：
  GET  /wxticket → 微信 qrconnect 取 uuid → 长轮询 long.open.weixin.qq.com 拿 wx_code
  → POST /login（wx_code 换 accessToken/refreshToken）；过期后 POST /login 带 refreshToken 续期。
请求头固定为 ``vid`` / ``accessToken`` 加 App 版本头。vid/accessToken 同时就是网页会话
（当 wr_vid/wr_skey Cookie 可用），直接落在这两个字段；``eink`` 字段只存 refresh_token 与 device_id。
网络仅异步：Request.request。

@module koplugin.book.source.wechat.eink
--]]

local JSON = require("json")
local logger = require("utils.log")
local Request = require("http.request")
local Header = require("http.request.header")
local Text = require("utils.text")
local App = require("source.wechat.app")
local sha256 = require("ffi/sha2").sha256
local _ = require("gettext")

local Eink = {}

local API = "https://i.weread.qq.com"
local WX_APPID = "wxab9b71ad2b90ff34"
local WX_SCOPE = "snsapi_userinfo,snsapi_timeline,snsapi_friend"
local DEVICE_NAME = "Xiaomi"
local DEVICE_TYPE = 1
local QR_DEADLINE = 5 * 60
local QR_POLL_TIMEOUT = 65

-- 官方手机 App 10.2.2 的身份（抓包取得）；/book/read 的防重放签名只有这个渠道会下发 guest_token。
local VERSION_HEADERS = {
    ["User-Agent"] = "WeRead/10.2.2 WRBrand/xiaomi Dalvik/2.1.0 (Linux; U; Android 17; 25128PNA1C Build/CP2A.260605.016)",
    baseapi = "37",
    appver = "10.2.2.10167650",
    basever = "10.2.2.10167650",
    osver = "17",
    channelId = "12",
}

---@class WechatEinkCredentials
---@field vid string
---@field access_token string
---@field refresh_token string
---@field device_id string

--- wechat 源配置（会话字段与用户信息都在这里）。
---@return table
function Eink.config()
    return require("utils.settings").getSource("wechat")
end

---@param patch table 合并进 wechat 源配置并落盘
function Eink.save(patch)
    local MoonSettings = require("utils.settings")
    local c = MoonSettings.getSource("wechat")
    for k, v in pairs(patch) do c[k] = v end
    MoonSettings.saveSource("wechat", c)
end

--- 令牌就是网页会话（wr_vid/wr_skey 当 Cookie 可用），只落一份；eink 表只放续期要的两项。
---@param vid string
---@param access_token string
---@param refresh_token string
---@param device_id string
local function saveSession(vid, access_token, refresh_token, device_id)
    local eink = Eink.config().eink or {}
    eink.refresh_token, eink.device_id = refresh_token, device_id
    Eink.save({
        wr_vid = vid,
        wr_skey = access_token,
        user_id = vid,
        eink = eink,
    })
end

---@param n integer
---@return string
local function digits(n)
    local out = {}
    for i = 1, n do out[i] = tostring(math.random(0, 9)) end
    return table.concat(out)
end

--- 设备 ID：App 的是 38 位数字串，首位非零。
---@return string
function Eink.newDeviceId()
    return tostring(math.random(1, 9)) .. digits(37)
end

--- 已落盘设备 ID；没有就生成并落盘。重新登录沿用同一设备，避免在账号里堆设备。
--- 墨水屏时代的 "eink…" 前缀 ID 配手机渠道，续期会被风控回 -2041，登录时换成数字 ID。
---@return string
function Eink.deviceId()
    local eink = Eink.config().eink or {}
    if type(eink.device_id) == "string" and eink.device_id:match("^%d+$") then
        return eink.device_id
    end
    eink.device_id = Eink.newDeviceId()
    Eink.save({ eink = eink })
    return eink.device_id
end

--- 已落盘安装 ID（App 上报时长要带）；没有就生成并落盘。
---@return string
function Eink.installId()
    local eink = Eink.config().eink or {}
    if type(eink.install_id) ~= "string" or eink.install_id == "" then
        eink.install_id = "31" .. digits(26)
        Eink.save({ eink = eink })
    end
    return eink.install_id
end

--- 登录与续期共用的签名：sha256(毫秒时间戳 .. deviceId .. random)。
---@param timestamp number 毫秒
---@param device_id string
---@param random integer
---@return string
function Eink.signature(timestamp, device_id, random)
    return sha256(string.format("%.0f", timestamp) .. device_id .. tostring(random)) --[[@as string]]
end

---@return number
local function nowMs()
    return os.time() * 1000 + math.random(0, 999)
end

---@return WechatEinkCredentials|nil
function Eink.credentials()
    local c = Eink.config()
    local eink = c.eink
    if type(eink) ~= "table" or type(eink.refresh_token) ~= "string" or eink.refresh_token == ""
        or type(c.wr_skey) ~= "string" or c.wr_skey == "" then
        return nil
    end
    return { vid = c.wr_vid, access_token = c.wr_skey, refresh_token = eink.refresh_token, device_id = eink.device_id }
end

---@return boolean
function Eink.hasSession()
    return Eink.credentials() ~= nil
end

--- 清除续期令牌，保留设备 ID；网页会话字段由 Auth.clearSession 负责。
function Eink.clearSession()
    Eink.save({ eink = { device_id = (Eink.config().eink or {}).device_id } })
end

---@param extra table|nil
---@return table
local function versionHeaders(extra)
    return Header.merge(extra, VERSION_HEADERS)
end

---@param raw string|nil
---@return table|nil
local function decode(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, data = pcall(require("utils.json").decode, raw)
    if ok and type(data) == "table" then return data end
    return nil
end

---@param data table|nil
---@return number|nil
local function errCode(data)
    if type(data) ~= "table" then return nil end
    return tonumber(data.errCode or data.errcode)
end

---@param data table|nil
---@return string
local function errMsg(data)
    if type(data) ~= "table" then return "" end
    return tostring(data.errMsg or data.errmsg or "")
end

--- POST /login 回包 → 凭据；缺令牌按失败。续期回包可不带 refreshToken，表示沿用旧的。
---@param res table|nil
---@param err any
---@param old_refresh string|nil 续期时传入当前 refreshToken
---@return table|nil data, string|nil err
local function loginResult(res, err, old_refresh)
    if err then return nil, tostring(err) end
    local data = decode(res and res.body)
    if data and data.refreshToken == nil then data.refreshToken = old_refresh end
    if not res or not Request.ok(res.code) or not data
        or type(data.accessToken) ~= "string" or data.accessToken == ""
        or type(data.refreshToken) ~= "string" or data.refreshToken == "" then
        return nil, _("登录失败") .. " " .. tostring(errCode(data) or (res and res.code)) .. " " .. errMsg(data)
    end
    return data
end

---@param body table
---@param cb fun(res: table|nil, err: any)
---@return HttpJob
local function postLogin(body, cb)
    return Request.request({
        url = API .. "/login",
        method = "POST",
        body = JSON.encode(body),
        headers = versionHeaders({ ["Content-Type"] = "application/json; charset=UTF-8" }),
        timeout = require("http.timeout").net(1),
    }, cb)
end

--- 申请二维码：/wxticket 取票据，再向微信开放平台换 uuid。
---@param cb fun(info: { uid: string, qr_payload: string }|nil, err: string|nil)
---@return { cancel: fun() }
function Eink.beginQrLoginAsync(cb)
    local cancelled, job = false, nil
    job = Request.request({
        url = API .. "/wxticket?nonceStr=weread",
        method = "GET",
        headers = versionHeaders(),
        timeout = require("http.timeout").net(1),
    }, function(res, err)
        if cancelled then return end
        local ticket = not err and res and Request.ok(res.code) and decode(res.body) or nil
        if not ticket or type(ticket.signature) ~= "string" or ticket.timeStamp == nil then
            cb(nil, _("获取二维码票据失败"))
            return
        end
        job = Request.request({
            url = "https://open.weixin.qq.com/connect/sdk/qrconnect?" .. Text.formEncode({
                appid = WX_APPID,
                noncestr = "weread",
                timestamp = tostring(ticket.timeStamp),
                scope = WX_SCOPE,
                signature = ticket.signature,
            }),
            method = "GET",
            headers = { ["User-Agent"] = VERSION_HEADERS["User-Agent"] },
            timeout = require("http.timeout").net(1),
        }, function(res2, err2)
            if cancelled then return end
            local qr = not err2 and res2 and Request.ok(res2.code) and decode(res2.body) or nil
            if not qr or tonumber(qr.errcode) ~= 0 or type(qr.uuid) ~= "string" or qr.uuid == "" then
                cb(nil, _("获取二维码失败"))
                return
            end
            cb({
                uid = qr.uuid,
                qr_payload = "https://open.weixin.qq.com/connect/confirm?uuid=" .. Text.urlEncode(qr.uuid),
            })
        end)
    end)
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
        end }
end

--- 长轮询扫码状态：408 继续等、404 已扫码继续等、405 确认拿 wx_code、402/403 失败。
---@param uuid string
---@param cb fun(info: { wx_code: string }|nil, err: string|nil, status: string)
---@return { cancel: fun() }
function Eink.waitQrLoginAsync(uuid, cb)
    local cancelled, job, last = false, nil, nil
    local deadline = os.time() + QR_DEADLINE
    local function poll()
        if cancelled then return end
        local remaining = deadline - os.time()
        if remaining <= 0 then
            cb(nil, _("二维码已失效，请重新登录"), "error")
            return
        end
        local query = { f = "json", uuid = uuid, last = last }
        job = Request.request({
            url = "https://long.open.weixin.qq.com/connect/l/qrconnect?" .. Text.formEncode(query),
            method = "GET",
            headers = { ["User-Agent"] = "Mozilla/5.0" },
            timeout = math.min(QR_POLL_TIMEOUT, remaining),
        }, function(res, err)
            if cancelled then return end
            if err then
                if os.time() < deadline then
                    require("ui/uimanager"):scheduleIn(3, poll)
                else
                    cb(nil, tostring(err), "error")
                end
                return
            end
            local data = res and Request.ok(res.code) and decode(res.body) or nil
            local code = data and tonumber(data.wx_errcode)
            if code == 405 and type(data.wx_code) == "string" and data.wx_code ~= "" then
                cb({ wx_code = data.wx_code }, nil, "ok")
            elseif code == 404 or code == 408 then
                last = code
                poll()
            elseif code == 403 then
                cb(nil, _("已在微信中拒绝登录"), "error")
            else
                cb(nil, _("二维码已失效，请重新登录"), "error")
            end
        end)
    end
    poll()
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
        end }
end

--- wx_code 换令牌并落盘。
---@param info { wx_code: string }
---@param cb fun(user: { user_id: string, user_name: string }|nil, err: string|nil)
---@return HttpJob
function Eink.completeQrLoginAsync(info, cb)
    local device_id = Eink.deviceId()
    local timestamp, random = nowMs(), math.random(0, 999)
    return postLogin({
        appFirstInstall = 1,
        code = info.wx_code,
        deviceId = device_id,
        deviceName = DEVICE_NAME,
        installId = Eink.installId(),
        isAutoLogout = 0,
        isFromQrcode = 1,
        random = random,
        signature = Eink.signature(timestamp, device_id, random),
        timestamp = timestamp,
        trackId = "",
        deviceType = DEVICE_TYPE,
    }, function(res, err)
        local data, login_err = loginResult(res, err)
        if not data then
            cb(nil, login_err)
            return
        end
        local vid = tostring(data.vid)
        saveSession(vid, data.accessToken, data.refreshToken, device_id)
        -- 可能换了账号：上一个账号的 entered 状态留着，新账号的时长会因缺「进入阅读」不计。
        require("source.wechat.context").clear()
        logger.info("weread eink login ok", vid)
        cb({ user_id = vid, user_name = "" })
    end)
end

--- 在飞续期的等待者；并发请求共享同一次 /login。
---@type (fun(ok: boolean, err: string|nil, rejected: boolean|nil))[]|nil
local mint_waiters

--- 是否有续期在飞（调用方据此排队而不是另起 / 走冷却）。
---@return boolean
function Eink.refreshing()
    return mint_waiters ~= nil
end

--- App 防重放签名用的 guest_token（``/feature`` 配置同名项），落 cfg.eink.guest_token。
---@param token string
function Eink.setGuestToken(token)
    local eink = Eink.config().eink or {}
    eink.guest_token = token
    Eink.save({ eink = eink })
end

---@param creds WechatEinkCredentials
---@param cb fun(token: string)
local function withGuestToken(creds, cb)
    local cached = (Eink.config().eink or {}).guest_token
    if type(cached) == "string" and cached ~= "" then
        cb(cached)
        return
    end
    Request.request({
        url = API .. "/feature?synckey=0",
        method = "GET",
        headers = versionHeaders({ vid = creds.vid, accessToken = creds.access_token }),
        timeout = require("http.timeout").net(1),
    }, function(res, err)
        local data = not err and res and Request.ok(res.code) and decode(res.body) or nil
        local token = data and type(data.feature) == "table" and data.feature.guest_token
        if type(token) == "string" and token ~= "" then
            Eink.setGuestToken(token)
            cb(token)
        else
            cb("")
        end
    end)
end

--- 用 refreshToken 换新 accessToken 并落盘。
--- rejected 只在服务器明确拒绝（有回包且非 5xx）时为真；超时 / 断网 / 5xx 不能当成登录失效。
---@param cb fun(ok: boolean, err: string|nil, rejected: boolean|nil)
function Eink.refreshAsync(cb)
    if mint_waiters then
        mint_waiters[#mint_waiters + 1] = cb
        return
    end
    local creds = Eink.credentials()
    if not creds then
        cb(false, _("请先扫码登录微信读书墨水屏"))
        return
    end
    mint_waiters = { cb }
    local timestamp, random = nowMs(), math.random(0, 999)
    -- App 续期的防重放签名要 guest_token；没缓存时取一次（拿不到就空串，由服务端决定）。
    withGuestToken(creds, function(guest_token)
    postLogin({
        deviceId = creds.device_id,
        deviceName = DEVICE_NAME,
        inBackground = 0,
        kickType = 1,
        random = random,
        refCgi = "",
        refreshToken = creds.refresh_token,
        signature = App.sign({
            guest_token, creds.device_id, string.format("%.0f", timestamp), tostring(random), creds.refresh_token,
        }),
        timestamp = timestamp,
        trackId = "",
        wxToken = 0,
    }, function(res, err)
        local data, login_err = loginResult(res, err, creds.refresh_token)
        if data then
            saveSession(data.vid ~= nil and tostring(data.vid) or creds.vid,
                data.accessToken, data.refreshToken, creds.device_id)
        else
            logger.warn("weread eink refresh failed", login_err)
        end
        local waiters = mint_waiters
        mint_waiters = nil
        local rejected = data == nil and not err and res ~= nil and (tonumber(res.code) or 0) < 500
        for _idx, waiter in ipairs(waiters) do waiter(data ~= nil, login_err, rejected) end
    end)
    end)
end

---@class WechatEinkCallMeta
---@field status integer|nil HTTP 状态码
---@field errcode number|nil 业务 errCode
---@field body table|nil 解码后的回包

--- 调 Eink API。401 / -2012 先续期：GET 或 ``opts.idempotent`` 重放一次；
--- 写请求只续期不重放（可能已落地，重放会重复写）。-2041 是人机验证，直接失败。
---@param method string
---@param path string 以 / 开头，相对 i.weread.qq.com
---@param opts { query: table|nil, body: table|nil, idempotent: boolean|nil, raw: boolean|nil }|nil raw：2xx 非 JSON 回包（zip）原样交给 cb（data = res），错误仍按 JSON 解码
---@param cb fun(data: table|nil, err: string|nil, meta: WechatEinkCallMeta)
---@return { cancel: fun() }
function Eink.callAsync(method, path, opts, cb)
    opts = opts or {}
    local replayable = opts.idempotent == true or method == "GET"
    local cancelled, job = false, nil
    local url = API .. path
    if opts.query then url = url .. "?" .. Text.formEncode(opts.query) end
    local function attempt(n)
        local creds = Eink.credentials()
        if not creds then
            cb(nil, _("请先扫码登录微信读书墨水屏"), {})
            return
        end
        local headers = versionHeaders({ vid = creds.vid, accessToken = creds.access_token })
        if opts.body then headers["Content-Type"] = "application/json; charset=UTF-8" end
        job = Request.request({
            url = url,
            method = method,
            body = opts.body and JSON.encode(opts.body) or nil,
            headers = headers,
            timeout = require("http.timeout").net(1),
        }, function(res, err)
            if cancelled then return end
            if err then
                cb(nil, tostring(err), {})
                return
            end
            if opts.raw and Request.ok(res.code) and res.body:sub(1, 2) == "PK" then
                cb(res, nil, { status = res.code })
                return
            end
            local data = decode(res.body)
            local code = errCode(data)
            local meta = { status = res.code, errcode = code, body = data }
            if n == 1 and (res.code == 401 or code == -2012) then
                Eink.refreshAsync(function(ok, refresh_err)
                    if cancelled then return end
                    if ok and replayable then
                        attempt(2)
                    else
                        cb(nil, refresh_err or _("鉴权失败，请求结果未知"), meta)
                    end
                end)
                return
            end
            if code == -2041 then
                cb(nil, _("需要在微信读书官方客户端完成人机验证") .. " (-2041)", meta)
                return
            end
            if not Request.ok(res.code) or (code ~= nil and code ~= 0) or not data then
                cb(nil, tostring(code or ("HTTP " .. tostring(res.code))) .. " " .. errMsg(data), meta)
                return
            end
            cb(data, nil, meta)
        end)
    end
    attempt(1)
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
        end }
end

return Eink
