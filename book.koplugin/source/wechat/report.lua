--[[--
微信读书阅读时长上报：对齐 web/book/read 周期心跳。

@module koplugin.book.source.wechat.report
--]]

local JSON = require("json")
local logger = require("logger")
local Protocol = require("source.wechat.protocol")
local Context = require("source.wechat.context")
local ProgressPosition = require("types.book_progress")

local Report = {}

local INTERVAL = 30
local MIN_INTERVAL = 10

---@class WechatReadReporter
---@field _client table
---@field _job table|nil
---@field _book_id string|nil
---@field _entered boolean
---@field _last_at integer|nil
---@field _pclts string|nil
---@field _session_id string

---@param client table
---@return WechatReadReporter
function Report.new(client)
    ---@type WechatReadReporter
    return setmetatable({
        _client = client,
        _session_id = tostring({}) .. ":" .. tostring(os.time()),
    }, { __index = Report })
end

---@param self WechatReadReporter
local function resetSession(self)
    self._book_id = nil
    self._entered = false
    self._last_at = nil
    self._pclts = nil
    if self._job and self._job.cancel then
        self._job:cancel()
    end
    self._job = nil
end

---@param self WechatReadReporter
---@param identity BookIdentity
---@param pos ProgressPosition|nil
---@return table|nil
local function positionPayload(self, identity, pos)
    pos = pos or {}
    local chapter_uid
    if pos.chapter_uid then
        chapter_uid = pos.chapter_uid
    elseif identity.chapter_idx then
        local payload = require("utils.db.toc").get(identity.source_id, identity.stable_id, 6 * 60 * 60)
        if payload then
            local ok, toc = pcall(function() return require("json").decode(payload) end)
            if ok and type(toc) == "table" then
                local ch = toc[tonumber(identity.chapter_idx) or 0]
                chapter_uid = ch and ch.uid
            end
        end
    end
    if not chapter_uid then return nil end
    local psvts = Context.psvts(identity.stable_id, chapter_uid)
    if not psvts then return nil end
    local frac = ProgressPosition.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    local chapter_frac = pos.chapter_fraction
    local offset = chapter_frac and math.floor(chapter_frac * 10000) or 0
    if not self._pclts or self._book_id ~= identity.stable_id then
        self._pclts = Protocol.encode(os.time())
    end
    return {
        book_id = identity.stable_id,
        chapter_uid = chapter_uid,
        chapter_idx = tonumber(identity.chapter_idx) or 0,
        chapter_offset = offset,
        progress = progress,
        summary = pos.chapter_title or "",
        psvts = psvts,
        pclts = self._pclts,
    }
end

---@param self WechatReadReporter
---@param identity BookIdentity
---@param pos ProgressPosition|nil
---@param elapsed integer|nil
---@param cb fun(ok: boolean|nil, err: any)|nil
local function sendOnce(self, identity, pos, elapsed, cb)
    local ctx = positionPayload(self, identity, pos)
    if not ctx then
        if cb then cb(nil, "missing reader context") end
        return
    end
    local referer = Protocol.readerUrl(ctx.book_id, ctx.chapter_uid)
    local function report(payload, done)
        self._job = self._client:reportReadAsync(JSON.encode(payload), referer, function(data, err)
            self._job = nil
            if data then
                done(true)
            else
                done(nil, err)
            end
        end)
    end
    if not self._entered or self._book_id ~= identity.stable_id then
        self._entered = true
        self._book_id = identity.stable_id
        report(Protocol.makeEnterReadPayload(ctx), function(ok, err)
            if not ok then
                self._entered = false
                if cb then cb(nil, err) end
                return
            end
            report(Protocol.makeReadPayload(setmetatable({
                elapsed_seconds = elapsed or INTERVAL,
            }, { __index = ctx })), cb)
        end)
        return
    end
    report(Protocol.makeReadPayload(setmetatable({
        elapsed_seconds = elapsed or INTERVAL,
    }, { __index = ctx })), cb)
end

--- 翻页/心跳：距上次满 INTERVAL 秒则上报。
---@param self WechatReadReporter
---@param identity BookIdentity
---@param pos ProgressPosition|nil
function Report.onPageChanged(self, identity, pos)
    if not identity or identity.source_id ~= "wechat" then return end
    if self._book_id and self._book_id ~= identity.stable_id then
        resetSession(self)
    end
    local now = os.time()
    if self._last_at and now - self._last_at < MIN_INTERVAL then
        return
    end
    if self._job then return end
    local elapsed = self._last_at and (now - self._last_at) or INTERVAL
    if self._last_at and now - self._last_at < INTERVAL then
        return
    end
    sendOnce(self, identity, pos, elapsed, function(ok, err)
        if ok then
            self._last_at = now
        elseif err then
            logger.dbg("wechat read report failed", identity.stable_id, err)
        end
    end)
end

--- 关书前结清剩余时长。
---@param self WechatReadReporter
---@param identity BookIdentity|nil
---@param pos ProgressPosition|nil
---@param cb fun()|nil
function Report.onDocumentClose(self, identity, pos, cb)
    if not identity and self._book_id then
        identity = { source_id = "wechat", stable_id = self._book_id }
    end
    if not identity or identity.source_id ~= "wechat" or not self._last_at then
        resetSession(self)
        if cb then cb() end
        return
    end
    local elapsed = math.max(MIN_INTERVAL, os.time() - (self._last_at or os.time()))
    if self._job then
        resetSession(self)
        if cb then cb() end
        return
    end
    sendOnce(self, identity, pos, elapsed, function()
        resetSession(self)
        if cb then cb() end
    end)
end

--- 用本地 reading_stats 行补报离线时长。
---@param self WechatReadReporter
---@param rows table[]
---@param cb fun(ok: boolean|nil, err: any)
function Report.pushStatsRows(self, rows, cb)
    rows = rows or {}
    if #rows == 0 then
        cb({ ok = true })
        return
    end
    local by_book = {}
    for _, row in ipairs(rows) do
        if type(row.stable_id) == "string" and row.stable_id ~= "" then
            local bucket = by_book[row.stable_id]
            if not bucket then
                bucket = { duration = 0, page = row.page or 0 }
                by_book[row.stable_id] = bucket
            end
            bucket.duration = bucket.duration + (tonumber(row.duration) or 0)
            bucket.page = tonumber(row.page) or bucket.page
        end
    end
    local ids = {}
    for id in pairs(by_book) do ids[#ids + 1] = id end
    table.sort(ids)
    local index = 1
    local function nextBook()
        local stable_id = ids[index]
        index = index + 1
        if not stable_id then
            cb({ ok = true })
            return
        end
        local bucket = by_book[stable_id]
        local identity = { source_id = "wechat", stable_id = stable_id }
        local pos = {
            fraction = math.min(1, (tonumber(bucket.page) or 0) / 100),
            page = bucket.page,
        }
        sendOnce(self, identity, pos, bucket.duration, function(ok, err)
            if not ok then
                logger.dbg("wechat stats push skip", stable_id, err)
            end
            nextBook()
        end)
    end
    nextBook()
end

return Report
