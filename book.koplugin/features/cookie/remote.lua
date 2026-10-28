--[[--
浏览器授权登录的远程管理接口（/api/cookie/*），协议见浏览器扩展 moon-cookie-storage 的 README「远程管理接入协议 v1」。

  GET  sources                 支持浏览器登录的数据源 [{ id, name, icon, authorized }]
  POST ticket {source}         签发一次性 ticket，回扩展要的任务参数 { domain, scope, login, check, check_json?, ticket, callback }
  GET  login?data=<信封>       扩展回调：解密 → 数据源 apply → { ok, close, ticketId }

数据源在 setting.lua 声明 `Setting.browser = { domain, scope, login, check, check_json?, icon, isAuthorized, apply(payload, cb(ok, err)) }`：
payload 是扩展采集的明文（cookies / local / session），apply 负责校验登录态并保存。
ticket 只在内存里：10 分钟过期；成功后保留回执 2 分钟，重复回调返回同一确认（幂等）。

@module koplugin.book.features.cookie.remote
--]]

local Gcm = require("crypto.gcm")
local sha2 = require("ffi/sha2")
local Text = require("utils.text")
local _ = require("gettext")

local Remote = {}

local TICKET_TTL = 10 * 60
local RECEIPT_TTL = 2 * 60
local CALLBACK = "/api/cookie/login"

---@type table<string, { ticket: string, source: string, expires: integer, receipt_until: integer|nil, pending: function[]|nil }>
local tickets = {}

---@param s string
---@return string
local function b64url(s)
    return (Text.base64Encode(s):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

---@param s string
---@return string
local function unb64url(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    return Text.base64Decode(s .. string.rep("=", (4 - #s % 4) % 4))
end

---@return string
local function randomTicket()
    local f = assert(io.open("/dev/urandom", "rb"))
    local bytes = f:read(32)
    f:close()
    return b64url(bytes)
end

-- 每个源本进程内成功授权的次数。已授权的源重新授权时，网页靠它判断新一轮授权是否完成。
---@type table<string, integer>
local applied = {}

local function sweep(now)
    for id, entry in pairs(tickets) do
        if entry.expires < now and not (entry.receipt_until and entry.receipt_until >= now) then tickets[id] = nil end
    end
end

---@return table[]
local function sources()
    local out = {}
    local Registry = require("source.registry")
    local SourceSetting = require("desktop.pages.setting.source")
    for _idx, meta in ipairs(Registry.list()) do
        local setting = SourceSetting.loadSetting(meta.id)
        if setting and type(setting.browser) == "table" then
            local browser = setting.browser
            out[#out + 1] = {
                id = meta.id, name = meta.name, login = browser.login, icon = browser.icon,
                authorized = type(browser.isAuthorized) == "function" and browser.isAuthorized() or false,
                auth_seq = applied[meta.id] or 0,
                browser = browser,
            }
        end
    end
    return out
end

---@param id string
---@return table|nil, table|nil
local function findSource(id)
    for _idx, item in ipairs(sources()) do
        if item.id == id then return item.browser, item end
    end
end

---@param data string 信封 JSON
---@return table|nil entry, table|nil payload, string|nil err, string|nil ticket_id
local function open(data)
    local env = require("utils.json").decode(data)
    if type(env) ~= "table" or env.v ~= 1 or type(env.ticketId) ~= "string" then return nil, nil, _("信封格式不对") end
    local entry = tickets[env.ticketId]
    if not entry then return nil, nil, _("授权已过期，请回到网页重新发起"), env.ticketId end
    if not (type(env.salt) == "string" and type(env.iv) == "string" and type(env.data) == "string") then
        return nil, nil, _("信封格式不对")
    end
    local key = Gcm.hkdf(entry.ticket, unb64url(env.salt), "moon-cookie-storage/v1", 32)
    local plain = Gcm.decrypt(key, unb64url(env.iv), entry.ticket, unb64url(env.data))
    if not plain then return nil, nil, _("解密失败") end
    local payload = require("utils.json").decode(plain)
    if type(payload) ~= "table" or payload.ticket ~= entry.ticket then return nil, nil, _("授权内容不匹配") end
    return entry, payload, nil, env.ticketId
end

---@param cb fun(status: integer, body: table, headers: string[]|nil)
local function login(params, cb)
    local function reply(status, body)
        cb(status, body, { "Cache-Control: no-store" })
    end
    local now = os.time()
    sweep(now)
    local entry, payload, err, ticket_id = open(tostring(params.data or ""))
    if not entry then return reply(400, { error = err }) end
    if entry.receipt_until then
        return reply(200, { ok = true, close = true, ticketId = ticket_id })
    end
    if entry.expires < now then return reply(400, { error = _("授权已过期，请回到网页重新发起") }) end
    if entry.applying then return reply(409, { error = _("正在校验，请稍候") }) end
    local browser = findSource(entry.source)
    if not browser or payload.domain ~= browser.domain or payload.check ~= browser.check then
        return reply(400, { error = _("授权域名与数据源不符") })
    end
    entry.applying = true
    browser.apply(payload, function(ok, apply_err)
        entry.applying = nil
        if not ok then return reply(400, { error = apply_err or _("登录校验失败") }) end
        applied[entry.source] = (applied[entry.source] or 0) + 1
        entry.receipt_until = os.time() + RECEIPT_TTL
        reply(200, { ok = true, close = true, ticketId = ticket_id })
    end)
end

---@param method string
---@param action string
---@param params table
---@param cb fun(status: integer, body: table, headers: string[]|nil)
function Remote.handle(method, action, params, cb)
    if action == "sources" and method == "GET" then
        local out = {}
        for _idx, item in ipairs(sources()) do
            out[#out + 1] = {
                id = item.id, name = item.name, icon = item.icon, authorized = item.authorized, auth_seq = item.auth_seq,
            }
        end
        return cb(200, { sources = out })
    elseif action == "ticket" and method == "POST" then
        local browser = findSource(tostring(params.source or ""))
        if not browser then return cb(404, { error = _("该数据源不支持浏览器登录") }) end
        local now = os.time()
        sweep(now)
        local ticket = randomTicket()
        tickets[b64url(sha2.hex_to_bin(sha2.sha256(ticket)))] = { ticket = ticket, source = params.source, expires = now + TICKET_TTL }
        return cb(200, {
            domain = browser.domain, scope = browser.scope, login = browser.login, check = browser.check, check_json = browser.check_json,
            ticket = ticket, callback = CALLBACK,
        })
    elseif action == "login" and method == "GET" then
        return login(params, cb)
    end
    return cb(404, { error = "Not Found" })
end

return Remote
