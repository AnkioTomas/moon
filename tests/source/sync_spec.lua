---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 源推脏行：hasDirty 只查库；pushDirty 入 sync 类可重跑任务，只推有脏行的域，进度在统计之后。 --]]

local Assert = require("support.assert")

local books, notes, stats_rows, progress = {}, {}, {}, {}
package.preload["book.books_db"] = function()
    return { unsynced = function() return books end }
end
package.preload["book.note_db"] = function()
    return { hasUnsynced = function() return #notes > 0 end }
end
package.preload["book.stats_db"] = function()
    return { unsyncedBySource = function() return stats_rows end }
end
package.preload["book.progress_db"] = function()
    return { unsynced = function() return progress end }
end
local enqueued = {}
package.preload["workers.tasks"] = function()
    return { enqueue = function(spec) enqueued[#enqueued + 1] = spec; return spec end }
end

local SourceBase = require("source.base")

--- 一个只记录同步调用的源。
---@param id string
---@return BookSource
local function sourceOf(id)
    local calls = {}
    local source = setmetatable({
        id = id,
        name = id .. "-name",
        calls = calls,
    }, { __index = SourceBase })
    local function record(name)
        return function(_, opts, cb)
            calls[#calls + 1] = { name, opts.dirty_only }
            cb({ pushed = 1 })
            return { cancel = function() end }
        end
    end
    source.syncBooksAsync = record("books")
    source.syncNotesAsync = record("notes")
    source.syncStatsAsync = record("stats")
    source.syncProgressAsync = record("progress")
    -- 能推的域看上行方法在不在
    source.pushNotesAsync = function() end
    source.pushStatsAsync = function() end
    source.putProgressAsync = function() end
    return source
end

--- 入队并立即跑一次任务，返回任务描述与 done 的结果。
local function runPush(source)
    enqueued = {}
    source:pushDirty()
    Assert.len(enqueued, 1)
    local spec, result = enqueued[1], nil
    spec.run(function() end, function(r) result = r end)
    return spec, result
end

-- hasDirty：没有脏行为假，任一域有脏行为真。
do
    books, notes, stats_rows, progress = {}, {}, {}, {}
    Assert.is_false(SourceBase.hasDirty("moon"))
    progress = { { stable_id = "b1" } }
    Assert.is_true(SourceBase.hasDirty("moon"))
end

-- 任务形状：按源唯一 key、sync 类、可重跑；失败才退避重试。
do
    books, notes, stats_rows, progress = { { stable_id = "b1" } }, {}, {}, {}
    local spec, result = runPush(sourceOf("moon"))
    Assert.eq(spec.key, "dirty\0moon")
    Assert.eq(spec.kind, "sync")
    Assert.eq(spec.title, "moon-name")
    Assert.is_true(spec.restartable)
    Assert.is_true(result.ok)
    Assert.is_false(spec.retryable({ ok = true }))
    Assert.is_true(spec.retryable({ ok = false }))
end

-- 只有书架脏：不顺手拉进度/笔记/统计，书架必须 dirty_only。
do
    books = { { stable_id = "b1" } }
    notes, stats_rows, progress = {}, {}, {}
    local source = sourceOf("moon")
    runPush(source)
    Assert.eq(#source.calls, 1)
    Assert.eq(source.calls[1][1], "books")
    Assert.is_true(source.calls[1][2])
end

-- 四个域都脏：书架、笔记、统计，进度最后；全部 dirty_only。
do
    books = { { stable_id = "b1" } }
    notes = { { stable_id = "b1" } }
    stats_rows = { { stable_id = "b1" } }
    progress = { { stable_id = "b1" } }
    local source = sourceOf("moon")
    runPush(source)
    local names = {}
    for _idx, call in ipairs(source.calls) do
        names[#names + 1] = call[1]
        Assert.is_true(call[2], call[1])
    end
    Assert.eq(table.concat(names, ","), "books,notes,stats,progress")
end

-- 书架失败不拦住后面的进度；整轮记失败，交给队列重试。
do
    books = { { stable_id = "b1" } }
    notes, stats_rows = {}, {}
    progress = { { stable_id = "b1" } }
    local source = sourceOf("moon")
    source.syncBooksAsync = function(_, opts, cb)
        source.calls[#source.calls + 1] = { "books", opts.dirty_only }
        cb(nil, "offline")
        return { cancel = function() end }
    end
    local _spec, result = runPush(source)
    Assert.eq(source.calls[1][1], "books")
    Assert.eq(source.calls[2][1], "progress")
    Assert.is_false(result.ok)
    Assert.eq(result.err, "offline")
end

-- 域整体成功但有脏行没推上去（push_error）：对推脏就是失败，交给队列退避重试，原因带上来。
do
    books, notes, stats_rows = {}, {}, {}
    progress = { { stable_id = "b1" } }
    local source = sourceOf("local")
    source.syncProgressAsync = function(_, _opts, cb)
        cb({ pushed = 0, push_error = "WebDAV 认证失败：用户名或密码错误" })
        return { cancel = function() end }
    end
    local _spec, result = runPush(source)
    Assert.is_false(result.ok)
    Assert.eq(result.err, "WebDAV 认证失败：用户名或密码错误")
end

-- 休眠中断：取消后不再推后面的域，也不回 done（队列放回等待，续跑时重新查脏行）。
do
    books = { { stable_id = "b1" } }
    notes, stats_rows = {}, {}
    progress = { { stable_id = "b1" } }
    local source = sourceOf("moon")
    local pending_cb, cancelled_job = nil, false
    source.syncBooksAsync = function(_, _opts, cb)
        pending_cb = cb
        return { cancel = function() cancelled_job = true end }
    end
    enqueued = {}
    source:pushDirty()
    local finished = false
    local handle = enqueued[1].run(function() end, function() finished = true end)
    handle.cancel()
    Assert.is_true(cancelled_job)
    pending_cb({ pushed = 1 })
    Assert.eq(#source.calls, 0, "取消后不推进度")
    Assert.is_false(finished)
end

-- 只有待上传笔记也算脏（经存在性查询，不读 payload）。
do
    books, notes, stats_rows, progress = {}, { { stable_id = "n1" } }, {}, {}
    Assert.is_true(SourceBase.hasDirty("moon"))
    notes = {}
end

-- 源没有某域的上行方法（jjwxc 没有远端进度）：该域的脏行不算，不入队、不调 sync；
-- 书架人人能推。
do
    books, notes, stats_rows = {}, {}, {}
    progress = { { stable_id = "b1" } }
    local source = sourceOf("jjwxc")
    source.putProgressAsync, source.pushNotesAsync, source.pushStatsAsync = nil, nil, nil
    enqueued = {}
    source:pushDirty()
    Assert.len(enqueued, 0, "没有能推的域就不入队")
    Assert.is_true(SourceBase.hasDirty("jjwxc"), "hasDirty 只查库，不看能力")

    notes = { { stable_id = "n1" } }
    books = { { stable_id = "b1" } }
    runPush(source)
    Assert.eq(#source.calls, 1)
    Assert.eq(source.calls[1][1], "books")
    books, notes, progress = {}, {}, {}
end
