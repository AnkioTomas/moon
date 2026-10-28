--[[--
浏览器配对：第一次访问的浏览器要在设备上点「允许」才能用远程管理。

令牌由设备签发、浏览器存 localStorage 并镜像进 Cookie `moon_token`，每个请求经 Cookie 带回；
`Pair.authorized(self, headers)` 由 server 在路由前调用。公开（免配对）的只有：静态资源、
/api/i18n、/api/pages、/api/pair 本身、设备主动分享出去的 /download 链接（handlers.is_shared）
与扩展提供者声明 `public = { [action] = true }` 的动作（浏览器扩展回调）。

  POST /api/pair {name}   发起配对：设备弹窗，回 { id }
  GET  /api/pair?id=      轮询：{ state = "pending"|"approved"|"denied", token? }

设备端（本文件下半部分，UI 函数内延迟加载）：同一时刻只有一个待批请求，新请求顶掉旧弹窗；
批准即签发令牌写进 `features.remote` 设置的 `remote_paired[token] = { name, at }`，撤销 = 清表。

@module koplugin.book.features.remote.pair
--]]

local JSON = require("json")
local _ = require("gettext")

local Pair = {}

Pair.BODY_LIMIT = 4096

--- 请求是否来自已配对浏览器。
---@param self table server
---@param headers table 已小写化的请求头
---@return boolean
function Pair.authorized(self, headers)
    local cookie = headers["cookie"]
    local token = type(cookie) == "string" and cookie:match("%f[%w_]moon_token=([%w]+)") or nil
    return token ~= nil and self.handlers.is_paired(token) == true
end

---@param self table server
---@param conn table
---@param method string
---@param headers table
---@param query table
function Pair.route(self, conn, method, headers, query)
    if method == "GET" then
        local state, token = self.handlers.pair_poll(query.id or "")
        return self:_json(conn, 200, JSON.encode({ state = state, token = token }))
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_acceptJson(conn, headers, Pair.BODY_LIMIT, function(server, c, body)
        local name = type(body) == "table" and body.name
        if type(name) ~= "string" or name == "" then
            return server:_fail(c, 400, "name required")
        end
        local id = server.handlers.pair_request(name:sub(1, 80), c.peer)
        return server:_json(c, 200, JSON.encode({ id = id }))
    end)
end

-- ── 设备端：待批请求 + 令牌表 ─────────────────────────

--- 当前待批请求：{ id, state, token?, dialog? }；批准 / 拒绝后留到被轮询到为止。
---@type table|nil
Pair._pending = nil

--- 32 个十六进制字符的随机串（/dev/urandom）。
---@return string
local function randomHex()
    local f = assert(io.open("/dev/urandom", "rb"))
    local bytes = f:read(16)
    f:close()
    return (bytes:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end

---@return table paired token → { name, at }
local function pairedTable()
    return require("utils.settings").get("features.remote").remote_paired
end

--- 令牌是否属于已配对浏览器。
---@param token string
---@return boolean
function Pair.isPaired(token)
    return pairedTable()[token] ~= nil
end

--- 已配对浏览器数。
---@return integer
function Pair.count()
    local n = 0
    for _token in pairs(pairedTable()) do n = n + 1 end
    return n
end

--- 撤销全部已配对浏览器：下次访问都要重新授权。
function Pair.revokeAll()
    local Settings = require("utils.settings")
    Settings.get("features.remote").remote_paired = {}
    Settings.save("features.remote")
end

--- 批准 / 拒绝：只对仍在等的那个请求生效（被顶掉的弹窗已关，回调不会再来）。
---@param pending table
---@param state "approved"|"denied"
local function settle(pending, state)
    if Pair._pending ~= pending then return end
    pending.state = state
    pending.dialog = nil
    if state == "approved" then
        local Settings = require("utils.settings")
        pending.token = randomHex()
        Settings.get("features.remote").remote_paired[pending.token] = { name = pending.name, at = os.time() }
        Settings.save("features.remote")
    end
end

--- 发起配对：顶掉上一个请求（关它的弹窗，它的轮询会得到 denied），弹设备端确认框。
---@param name string 浏览器名（网页自报）
---@param ip string|nil 对端地址
---@return string id
function Pair.request(name, ip)
    Pair.cancel()
    local pending = { id = randomHex(), name = name, state = "pending" }
    Pair._pending = pending
    local T = require("ffi/util").template
    pending.dialog = require("ui.themes.widgets.confirm"):new{
        title = _("远程管理授权请求"),
        text = T(_("浏览器「%1」（%2）请求访问远程管理。允许后它可以管理文件、输入与配置。"), name, ip or "?"),
        ok_text = _("允许"),
        cancel_text = _("拒绝"),
        ok_callback = function() settle(pending, "approved") end,
        cancel_callback = function() settle(pending, "denied") end,
    }
    pending.dialog:show()
    return pending.id
end

--- 轮询：批准 / 拒绝的结果只交付一次；不认识的 id 一律 denied。
---@param id string
---@return string state, string|nil token
function Pair.poll(id)
    local pending = Pair._pending
    if not pending or pending.id ~= id then
        return "denied"
    end
    if pending.state == "pending" then
        return "pending"
    end
    Pair._pending = nil
    return pending.state, pending.token
end

--- 丢弃当前请求（停服、新请求顶替）：弹窗直接关，不触发回调。
function Pair.cancel()
    local pending = Pair._pending
    Pair._pending = nil
    if pending and pending.dialog then
        pending.dialog:close()
    end
end

return Pair
