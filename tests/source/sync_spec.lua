---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 源 onNetworkConnected：只推本源有脏行的域，进度在统计之后。 --]]

local Assert = require("support.assert")

local books, notes, stats_rows, progress = {}, {}, {}, {}
package.preload["book.books_db"] = function()
    return { unsynced = function() return books end }
end
package.preload["book.note_db"] = function()
    return { unsynced = function() return notes end }
end
package.preload["book.stats_db"] = function()
    return { unsyncedBySource = function() return stats_rows end }
end
package.preload["book.progress_db"] = function()
    return { unsynced = function() return progress end }
end

local SourceBase = require("source.base")

--- 一个只记录同步调用的源。
---@param id string
---@return BookSource
local function sourceOf(id)
    local calls = {}
    local source = setmetatable({
        id = id,
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
    return source
end

-- 没有脏行：四个域都不碰。
do
    books, notes, stats_rows, progress = {}, {}, {}, {}
    local source = sourceOf("moon")
    source:onNetworkConnected({})
    Assert.eq(#source.calls, 0)
end

-- 只有书架脏：不顺手拉进度/笔记/统计，书架必须 dirty_only。
do
    books = { { stable_id = "b1" } }
    notes, stats_rows, progress = {}, {}, {}
    local source = sourceOf("moon")
    source:onNetworkConnected({})
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
    source:onNetworkConnected({})
    local names = {}
    for _idx, call in ipairs(source.calls) do
        names[#names + 1] = call[1]
        Assert.is_true(call[2], call[1])
    end
    Assert.eq(table.concat(names, ","), "books,notes,stats,progress")
end

-- 书架失败不拦住后面的进度。
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
    source:onNetworkConnected({})
    Assert.eq(source.calls[1][1], "books")
    Assert.eq(source.calls[2][1], "progress")
    Assert.is_true(source.calls[2][2])
end
