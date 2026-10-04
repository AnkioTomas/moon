--[[--
Turbo ioloop：按需泵。

不接管 UIManager.looper。对外只有一对进出：

  Turbo.acquire() → loop|nil   -- 建 loop、打补丁（http.patch）、占泵
  Turbo.release()              -- 对账，归零拆泵
  Turbo.client(proxy_url?) → client|nil, err         -- 按设置走代理（http.proxy）

@module koplugin.book.http.turbo
--]]

local UIManager = require("ui/uimanager")
local Patch = require("http.turbo.patch")
local Proxy = require("http.proxy")
local logger = require("utils.log")

---@class Turbo
local Turbo = {}

---@type table|nil turbo 模块，boot 成功后与 loop 同时置位
local turbo
local loop, pump, inflight = nil, nil, 0

------------------------------------------------------------------------
-- 泵：复制 start() 一拍，poll=0。禁止 start()。
------------------------------------------------------------------------

--- 推进自建 ioloop 一拍：协程、回调、到期 timeout，poll 超时 0。字段都是 turbo IOLoop 的私有实现。
---@param target table
local function pumpOnce(target)
    local co_cbs = target._co_cbs
    target._co_cbs = {}
    for i = 1, #co_cbs do
        if co_cbs[i] then
            target:_resume_coroutine(co_cbs[i][1], co_cbs[i][2])
        end
    end
    local callbacks = target._callbacks
    target._callbacks = {}
    for i = 1, #callbacks do
        target:_run_callback(callbacks[i])
    end
    local timeout_sz = target._timeouts_sz
    if timeout_sz > 0 then
        local now = require("turbo.util").gettimemonotonic()
        local ran, i = 0, 0
        -- 槽位可能有空洞；多扫 64 格兜底，计数错乱时不死循环。
        while ran ~= timeout_sz and i <= timeout_sz + 64 do
            local item = target._timeouts[i]
            if item ~= nil then
                ran = ran + 1
                if item:timed_out(now) == 0 then
                    target:_run_callback({ item:callback() })
                    target._timeouts[i] = nil
                    target._timeouts_sz = target._timeouts_sz - 1
                end
            end
            i = i + 1
        end
    end
    target:_event_poll(0)
end

--- 泵回调由 UIManager 驱动：抛错不能冒出去，否则带崩主循环。
local function kick()
    if loop and inflight > 0 then
        local ok, err = pcall(pumpOnce, loop)
        if not ok then
            logger.warn("book.http turbo pump", err)
        end
    end
end

--- 自建一只 IOLoop。禁止 ioloop.instance()：那是 UIManager.looper 的单例，
--- 一旦 start() 接管主循环，HID / 蓝牙翻页一起死。
---@return boolean ok
---@return string|nil err 失败原因（加载 turbo / 建 IOLoop 的原始错误）
local function boot()
    TURBO_SSL = true -- luacheck: ignore
    __TURBO_USE_LUASOCKET__ = true -- luacheck: ignore
    if not loop then
        local ok, mod = pcall(require, "turbo")
        if not ok then
            return false, tostring(mod)
        end
        local made, created = pcall(function() return mod.ioloop.IOLoop() end)
        if not made then
            return false, tostring(created)
        end
        if mod.log and mod.log.categories then
            mod.log.categories.success = false
            mod.log.categories.warning = false
        end
        turbo, loop = mod, created
    end
    Patch.apply()
    return true
end

--- 建自建 loop、打补丁、占泵（0→1 插 ZMQ + preventStandby）。
--- 失败返回 nil, err，调用方不要 release。
---@return table|nil ioloop
---@return string|nil err
function Turbo.acquire()
    local ok, err = boot()
    if not ok then
        logger.warn("book.http turbo unavailable", err)
        return nil, err
    end
    inflight = inflight + 1
    if inflight == 1 then
        pump = {
            waitEvent = kick,
            stop = function() end,
        }
        UIManager:insertZMQ(pump)
        UIManager:nextTick(kick)
        UIManager:preventStandby()
    end
    return loop
end

--- 对账。归零时拆泵并 allowStandby。多 acquire 必须成对 release。
function Turbo.release()
    if inflight == 0 then
        logger.warn("book.http pump release with no inflight")
        return
    end
    inflight = inflight - 1
    if inflight > 0 then
        return
    end
    UIManager:unschedule(kick)
    UIManager:removeZMQ(pump)
    pump = nil
    UIManager:allowStandby()
end

--- 新建 HTTPClient（verify_ca=false）。KOReader 开了 HTTP 代理时这个实例走代理。
---@param proxy_url string|nil 覆盖 KOReader 设置的代理（设置页实测未保存的地址）
---@return table|nil client
---@return any err
function Turbo.client(proxy_url)
    -- 没有自建 loop 时 HTTPClient 会落到 ioloop.instance()，即 UIManager.looper。
    if not loop then
        return nil, "turbo loop not acquired"
    end
    local made, client = pcall(turbo.async.HTTPClient, { verify_ca = false }, loop)
    if not made then
        return nil, client
    end
    Proxy.apply(client, proxy_url)
    return client
end

return Turbo
