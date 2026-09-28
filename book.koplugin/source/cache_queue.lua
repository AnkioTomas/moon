--[[--
章节全本缓存任务。排队、串行、退避重试都交给 `tasks`（lane = cache，全局一次只缓存一本，
避免多个详情页同时轰炸同一远端服务）；这里只定义怎么跑、何时可重试、完成怎么提示。
已成功章节落盘后，重试和再次入队都会跳过。

@module koplugin.book.source.cache_queue
--]]

require("l10n").apply()

local Tasks = require("tasks")
local _ = require("gettext")

local CacheQueue = {}

---@param source_id string
---@param stable_id string
---@return string
local function keyFor(source_id, stable_id)
    return "cache\0" .. tostring(source_id) .. "\0" .. tostring(stable_id)
end

---@param result table
---@return boolean
local function retryable(result)
    local text = tostring(result.err or "")
    return text:find("HTTP 425", 1, true) ~= nil
        or text:find("shard md5 mismatch", 1, true) ~= nil
end

---@param result table
local function notify(result)
    local text
    if result.ok then
        text = _("全本缓存完成：") .. tostring(result.cached) .. " / "
            .. tostring(result.total) .. _(" 章")
    elseif result.total > 0 then
        text = _("全本缓存部分完成：") .. tostring(result.cached) .. " / "
            .. tostring(result.total) .. _(" 章")
        if result.failed > 0 then
            text = text .. "，" .. tostring(result.failed) .. _(" 章失败")
        end
        if result.err then text = text .. "\n" .. tostring(result.err) end
    else
        text = tostring(result.err or _("全本缓存失败"))
    end
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = text, timeout = 5 })
end

--- 加入全本缓存队列。同一本书已在排队或运行时复用既有任务。
---@param source BookSource
---@param identity BookIdentity
---@return BookTask|nil task
---@return boolean queued 是否新入队
---@return string|nil reason 入队失败原因（目前只有 queue_full）
function CacheQueue.enqueue(source, identity)
    local book = identity.book or {}
    return Tasks.enqueue{
        key = keyFor(source.id, identity.stable_id),
        lane = "cache",
        label = _("缓存"),
        title = book.title or identity.title or identity.stable_id,
        restartable = true,
        retryable = retryable,
        on_done = notify,
        run = function(report, done)
            return source:cacheAllChaptersAsync(identity, function(cached, total)
                report(nil, cached, total)
            end, function(success, cached, err, total, failed)
                done({
                    ok = success and true or false,
                    cached = tonumber(cached) or 0,
                    total = tonumber(total) or 0,
                    failed = tonumber(failed) or 0,
                    err = err,
                })
            end)
        end,
    }
end

--- 这本书是否在缓存队列里（排队 / 运行 / 重试等待）。
---@param source_id string
---@param stable_id string
---@return boolean
function CacheQueue.has(source_id, stable_id)
    return Tasks.get(keyFor(source_id, stable_id)) ~= nil
end

return CacheQueue
