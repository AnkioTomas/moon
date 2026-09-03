--[[--
四类本地数据同步编排。只负责编排顺序、取消和汇总，不接触源协议。

@module koplugin.book.book.sync
--]]

local Sync = {}

local DOMAINS = {
    { name = "books", method = "syncBooksAsync" },
    { name = "progress", method = "syncProgressAsync" },
    { name = "notes", method = "syncNotesAsync" },
    { name = "stats", method = "syncStatsAsync" },
}

--- 按 Books → Progress → Notes → Stats 顺序同步一个源。
---@param source BookSource
---@param opts table|nil
---@param cb fun(result: table|nil, err: any)|nil
---@return { cancel: fun() }
function Sync.runAsync(source, opts, cb)
    opts = opts or {}
    local index, cancelled, current_job = 1, false, nil
    local summary = {
        domains = {}, pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
    }
    --- 终结整次编排并回调汇总；已取消时静默丢弃。
    ---@param value table|nil nil 表示某个域失败
    ---@param err any
    local function finish(value, err)
        if not cancelled and cb then cb(value, err) end
    end
    --- 同步下一个数据域，并把它的计数累加进汇总；域列表走完即 finish。
    --- 任一域失败立即中断后续域（部分成功的计数仍留在 summary 里但不回调）。
    --- 源未实现对应方法记为 skipped，不算失败。
    local function nextDomain()
        if cancelled then return end
        local domain = DOMAINS[index]
        index = index + 1
        if not domain then finish(summary); return end
        if opts.skip_books and domain.name == "books" then
            summary.domains.books = { skipped = true, reason = "not requested" }
            nextDomain()
            return
        end
        local method = source and source[domain.method]
        if type(method) ~= "function" then
            summary.domains[domain.name] = { skipped = true, reason = "unsupported" }
            nextDomain()
            return
        end
        local completed = false
        local job = method(source, opts, function(result, err)
            completed = true
            current_job = nil
            if cancelled then return end
            if not result then finish(nil, err); return end
            summary.domains[domain.name] = result
            summary.pulled = summary.pulled + (tonumber(result.pulled) or 0)
            summary.pushed = summary.pushed + (tonumber(result.pushed) or 0)
            summary.hidden = summary.hidden + (tonumber(result.hidden) or 0)
            summary.conflicts = summary.conflicts + (tonumber(result.conflicts) or 0)
            nextDomain()
        end)
        if not completed then current_job = job end
    end
    require("ui/uimanager"):nextTick(nextDomain)
    return { cancel = function()
        cancelled = true
        if current_job and current_job.cancel then current_job:cancel() end
    end }
end

--- 网络恢复时只重试有本地脏数据的源，不主动全量拉取。
---@return nil
function Sync.retryDirtyAsync()
    local Registry = require("source.registry")
    local ProgressDB = require("db.progress")
    local NoteDB = require("db.note")
    local StatsDB = require("db.stats")
    for _, meta in ipairs(Registry.listEnabled()) do
        local id = meta.id
        local dirty = #ProgressDB.unsynced(id) > 0
            or #NoteDB.unsynced(id) > 0
            or #StatsDB.unsyncedBySource(id) > 0
        if dirty then
            local source, err = Registry.resolve(id)
            if source then
                Sync.runAsync(source, { dirty_only = true, skip_books = true }, function(_, sync_err)
                    if sync_err then require("logger").warn("book dirty sync failed", id, sync_err) end
                end)
            elseif err then
                require("logger").warn("book dirty source unavailable", id, err)
            end
        end
    end
end

return Sync
