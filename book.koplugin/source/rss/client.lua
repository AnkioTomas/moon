--[[--
RSS 异步客户端：moon Request.get + 解析结果内存缓存。

@module koplugin.book.source.rss.client
--]]

local Request = require("http.request")
local Parser = require("source.rss.parser")

local Client = {}
Client.__index = Client

local CACHE_TTL = 15 * 60

function Client.new()
    return setmetatable({
        _cache = {},
        _inflight = {},
    }, Client)
end

function Client:clear()
    self._cache = {}
    for _, pending in pairs(self._inflight) do
        if pending.job and pending.job.cancel then
            pending.job.cancel()
        end
    end
    self._inflight = {}
end

---@param url string
---@return table|nil
function Client:peek(url)
    url = Parser.normalizeUrl(url)
    local row = url and self._cache[url]
    return row and row.data or nil
end

--- 拉取并解析 feed；同 URL 请求合并。
---@param raw_url string
---@param opts { force: boolean|nil }|nil
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }
function Client:fetchAsync(raw_url, opts, cb)
    opts = opts or {}
    local url = Parser.normalizeUrl(raw_url)
    if not url then
        cb(nil, "invalid feed URL")
        return { cancel = function() end }
    end
    local cached = self._cache[url]
    if not opts.force and cached and os.time() - cached.at < CACHE_TTL then
        cb(cached.data)
        return { cancel = function() end }
    end

    local pending = self._inflight[url]
    if pending then
        local waiter = { cb = cb, cancelled = false }
        pending.waiters[#pending.waiters + 1] = waiter
        return { cancel = function() waiter.cancelled = true end }
    end

    pending = {
        waiters = { { cb = cb, cancelled = false } },
    }
    self._inflight[url] = pending

    local function finish(data, err)
        self._inflight[url] = nil
        if data then self._cache[url] = { data = data, at = os.time() } end
        for _, waiter in ipairs(pending.waiters) do
            if not waiter.cancelled then waiter.cb(data, err) end
        end
    end

    pending.job = Request.get(url, {
        accept = "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
        timeout = 45,
    }, function(body, err)
        if not body then
            finish(nil, err or "feed request failed")
            return
        end
        local parsed, parse_err = Parser.parse(body, url)
        finish(parsed, parse_err)
    end)

    local first = pending.waiters[1]
    return {
        cancel = function()
            first.cancelled = true
            local active = false
            for _, waiter in ipairs(pending.waiters) do
                if not waiter.cancelled then active = true break end
            end
            if not active and pending.job and pending.job.cancel then
                pending.job.cancel()
                self._inflight[url] = nil
            end
        end,
    }
end

return Client
