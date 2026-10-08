--[[--
Kavita 简介/作者后台补全循环。

骨架 reconcile 完成后，逐本串行拉 ``GET /api/Series/metadata``，间隔 0.3s；
失败按 ``15*2^(n-1)`` 退避重试，最多 3 次，超出跳过。生命周期挂在源实例上，
``Source:close`` 或下一次同步时取消。不复用 cache_queue（槽位装不下全量，
且任务是 per-book 全本缓存形状）。

@module koplugin.book.source.kavita.backfill
--]]

local Backfill = {}
Backfill.__index = Backfill

local DEFAULT_INTERVAL = 0.3
local DEFAULT_RETRY_BASE = 15
local DEFAULT_MAX_ATTEMPTS = 3

---@param ts string|nil
---@return string
local function normalizeTs(ts)
    return type(ts) == "string" and ts or ""
end

--- 骨架快照里哪些 series 需要补全：状态里没见过，或 ``lastChapterAddedUtc`` 变了。
---@param series table<string, string|nil> seriesId → lastChapterAddedUtc
---@param stored table<string, string> 已补全状态（键存在即补过）
---@return table[] items 稳定排序的 ``{ stable_id, ts }``
function Backfill.plan(series, stored)
    local items = {}
    for stable_id, ts in pairs(series) do
        local key = tostring(stable_id)
        if stored[key] == nil or stored[key] ~= normalizeTs(ts) then
            items[#items + 1] = { stable_id = key, ts = normalizeTs(ts) }
        end
    end
    table.sort(items, function(a, b) return a.stable_id < b.stable_id end)
    return items
end

---@param opts { fetch: fun(item: table, cb: fun(data: table|nil, err: string|nil)):table|nil, on_success: fun(item: table, data: table), on_done: fun()|nil, schedule: fun(delay: number, fn: fun()):table|nil|nil, interval: number|nil, retry_base: number|nil, max_attempts: number|nil }
---@return Backfill
function Backfill.new(opts)
    return setmetatable({
        _fetch = opts.fetch,
        _on_success = opts.on_success,
        _on_done = opts.on_done,
        _schedule = opts.schedule or function(delay, fn)
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(delay, fn)
            return { cancel = function() UIManager:unschedule(fn) end }
        end,
        _interval = opts.interval or DEFAULT_INTERVAL,
        _retry_base = opts.retry_base or DEFAULT_RETRY_BASE,
        _max_attempts = opts.max_attempts or DEFAULT_MAX_ATTEMPTS,
        _items = {},
        _index = 0,
        _attempt = 0,
        _cancelled = false,
    }, Backfill)
end

--- 取消旧循环并开始新的补全队列。
---@param items table[]
---@return Backfill
function Backfill:run(items)
    self:cancel()
    self._cancelled = false
    self._items = items or {}
    self._index = 0
    self._attempt = 0
    self:_advance()
    return self
end

--- 前进到下一本；队列走完即停（回调 on_done）。
function Backfill:_advance()
    if self._cancelled then return end
    self._index = self._index + 1
    self._attempt = 0
    local item = self._items[self._index]
    if item then
        self:_request(item)
    elseif self._on_done then
        self._on_done()
    end
end

--- 拉一本的 metadata；成功写回并前进，失败退避重试或放弃。
---@param item table
function Backfill:_request(item)
    if self._cancelled then return end
    self._attempt = self._attempt + 1
    self._job = self._fetch(item, function(data, _err)
        if self._cancelled then return end
        self._job = nil
        if data then
            self._on_success(item, data)
            self:_later(self._interval)
        elseif self._attempt < self._max_attempts then
            self:_later(self._retry_base * (2 ^ (self._attempt - 1)), item)
        else
            self:_later(self._interval)
        end
    end)
end

---@param delay number
---@param retry_item table|nil 传入表示重试同一本，否则前进到下一本
function Backfill:_later(delay, retry_item)
    local go = function()
        self._timer = nil
        if self._cancelled then return end
        if retry_item then self:_request(retry_item) else self:_advance() end
    end
    self._timer = self._schedule(delay, go)
end

--- 停止循环并取消在途请求/等待定时器。
function Backfill:cancel()
    self._cancelled = true
    if self._job and self._job.cancel then self._job.cancel() end
    self._job = nil
    if self._timer and self._timer.cancel then self._timer.cancel() end
    self._timer = nil
end

return Backfill
