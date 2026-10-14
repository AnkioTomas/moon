--[[--
网络超时：用户只设两个「默认超时」秒数，代码里不再写死秒数，而是写「相对默认值的倍率」。

  - 「网络超时」network_timeout（秒，缺省 30）：普通请求。`Timeout.net(r)` = 设置 × r，
    例如下载 net(10)（缺省 300 秒）、番茄登录轮询 net(0.5)（15 秒）。不传 timeout 的请求 = net(1)，
    流式 / 下载缺省 net(6)；连接超时缺省 net(2 / 3)（20 秒），并且不超过整包超时。
  - 「AI 请求超时」ai_timeout（秒，缺省 120）：`Timeout.ai(r)` = 设置 × r，
    例如解释 ai(0.5)、摘要 ai(0.75)、报告 / X-Ray ai(1.5)；AI 请求只用这一项，不再乘网络超时。
调高调低完全对称；唯一下限 MIN_SECONDS = 1 秒，只为避免 0 超时。

@module koplugin.book.http.timeout
--]]

local Timeout = {}

--- 读配置表；拿不到（如精简的测试桩）就当空表，走缺省值。
---@param owner string
---@return table
local function conf(owner)
    local ok, cfg = pcall(function() return require("utils.settings").get(owner) end)
    return ok and type(cfg) == "table" and cfg or {}
end

Timeout.NETWORK_DEFAULT, Timeout.NETWORK_MIN, Timeout.NETWORK_MAX, Timeout.NETWORK_STEP = 30, 5, 300, 5
Timeout.AI_DEFAULT, Timeout.AI_MIN, Timeout.AI_MAX, Timeout.AI_STEP = 120, 10, 600, 10
--- 连接超时相对网络超时的缺省倍率（30 × 2/3 = 20 秒，即原先 turbo 的缺省）。
Timeout.CONNECT_RATIO = 2 / 3
Timeout.MIN_SECONDS = 1

---@param v any
---@param min number
---@param max number
---@param default number
---@return number
local function clamp(v, min, max, default)
    v = tonumber(v)
    if not v then return default end
    return math.max(min, math.min(max, math.floor(v)))
end

---@param base number
---@param ratio number|nil
---@return number
local function times(base, ratio)
    return math.max(Timeout.MIN_SECONDS, base * (ratio or 1))
end

--- 「网络超时」设置值（秒）。
---@return number
function Timeout.networkSeconds()
    return clamp(conf("http").network_timeout,
        Timeout.NETWORK_MIN, Timeout.NETWORK_MAX, Timeout.NETWORK_DEFAULT)
end

---@param v number
function Timeout.setNetworkSeconds(v)
    local MoonSettings = require("utils.settings")
    MoonSettings.get("http").network_timeout = clamp(v, Timeout.NETWORK_MIN, Timeout.NETWORK_MAX, Timeout.NETWORK_DEFAULT)
    MoonSettings.save("http")
end

--- 「AI 请求超时」设置值（秒）。
---@return number
function Timeout.aiSeconds()
    return clamp(conf("ai").ai_timeout, Timeout.AI_MIN, Timeout.AI_MAX, Timeout.AI_DEFAULT)
end

---@param v number
function Timeout.setAiSeconds(v)
    local MoonSettings = require("utils.settings")
    MoonSettings.get("ai").ai_timeout = clamp(v, Timeout.AI_MIN, Timeout.AI_MAX, Timeout.AI_DEFAULT)
    MoonSettings.save("ai")
end

--- 普通请求超时秒数 = 「网络超时」× ratio（缺省 1）。
---@param ratio number|nil
---@return number
function Timeout.net(ratio)
    return times(Timeout.networkSeconds(), ratio)
end

--- AI 请求超时秒数 = 「AI 请求超时」× ratio（缺省 1）。
---@param ratio number|nil
---@return number
function Timeout.ai(ratio)
    return times(Timeout.aiSeconds(), ratio)
end

--- 一次请求的 (整包超时, 连接超时)。
--- 调用方已用 net()/ai() 换算好的 timeout / connect_timeout 原样使用；没传就按 default_ratio × 网络超时。
---@param opts table HttpRequest
---@param default_ratio number|nil 未传 timeout 时的倍率（request 1 / stream 6）
---@return number request_timeout
---@return number connect_timeout
function Timeout.resolve(opts, default_ratio)
    local total = opts.timeout or Timeout.net(default_ratio)
    local connect = opts.connect_timeout or Timeout.net(Timeout.CONNECT_RATIO)
    return total, math.min(connect, total)
end

return Timeout
