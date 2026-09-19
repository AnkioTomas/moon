--[[-- book.sync：四域顺序、汇总、同步回调与取消。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.loaded["book.sync"] = nil
local Sync = require("book.sync")

-- Source 允许在调用栈内回调；编排必须保持固定顺序并正确汇总。
do
    local order = {}
    local source = { id = "moon" }
    local values = {
        syncBooksAsync = { pulled = 2, hidden = 1 },
        syncProgressAsync = { pulled = 1, pushed = 1 },
        syncNotesAsync = { pushed = 2, conflicts = 1 },
        syncStatsAsync = { pulled = 3, pushed = 4 },
    }
    for name, value in pairs(values) do
        source[name] = function(_, _, cb)
            order[#order + 1] = name
            cb(value)
            return { cancel = function() error("completed job must not be cancelled") end }
        end
    end
    local result
    Sync.runAsync(source, nil, function(value) result = value end)
    Stubs.flush()
    Assert.eq(table.concat(order, ","),
        "syncBooksAsync,syncProgressAsync,syncNotesAsync,syncStatsAsync")
    Assert.eq(result.pulled, 6)
    Assert.eq(result.pushed, 7)
    Assert.eq(result.hidden, 1)
    Assert.eq(result.conflicts, 1)
    Assert.eq(result.domains.notes, values.syncNotesAsync)
end

-- skip_books 不调用书架同步；取消在飞域后不再进入后续域，也不回调用户。
do
    local calls, pending, cancelled, finished = {}, nil, false, false
    local source = {
        syncBooksAsync = function() error("books must be skipped") end,
        syncProgressAsync = function(_, _, cb)
            calls[#calls + 1] = "progress"
            pending = cb
            return { cancel = function() cancelled = true end }
        end,
        syncNotesAsync = function()
            calls[#calls + 1] = "notes"
        end,
    }
    local job = Sync.runAsync(source, { skip_books = true }, function() finished = true end)
    Stubs.flush()
    Assert.eq(calls[1], "progress")
    job.cancel()
    Assert.is_true(cancelled)
    pending({ pushed = 1 })
    Assert.eq(#calls, 1)
    Assert.is_false(finished)
end

-- 编排层对进度/笔记强制 dirty_only（pull 只走开书路径）。
do
    local seen = {}
    local source = {
        id = "moon",
        syncBooksAsync = function(_, opts, cb)
            seen.books = opts.dirty_only
            cb({ pulled = 1 })
            return { cancel = function() end }
        end,
        syncProgressAsync = function(_, opts, cb)
            seen.progress = opts.dirty_only
            cb({ pushed = 1 })
            return { cancel = function() end }
        end,
        syncNotesAsync = function(_, opts, cb)
            seen.notes = opts.dirty_only
            cb({ pushed = 1 })
            return { cancel = function() end }
        end,
        syncStatsAsync = function(_, opts, cb)
            seen.stats = opts.dirty_only
            cb({ pulled = 1 })
            return { cancel = function() end }
        end,
    }
    Sync.runAsync(source, nil, function() end)
    Stubs.flush()
    Assert.is_nil(seen.books)
    Assert.is_true(seen.progress)
    Assert.is_true(seen.notes)
    Assert.is_nil(seen.stats)
end

-- retryDirtyAsync：有 books 脏行时不得 skip_books，且 books 带 dirty_only。
do
    local calls = {}
    package.preload["source.registry"] = function()
        return {
            listEnabled = function()
                return { { id = "moon" } }
            end,
            resolve = function()
                return {
                    id = "moon",
                    syncBooksAsync = function(_, opts, cb)
                        calls[#calls + 1] = {
                            "books", opts.skip_books, opts.dirty_only,
                        }
                        cb({ pushed = 1 })
                        return { cancel = function() end }
                    end,
                    syncProgressAsync = function(_, opts, cb)
                        calls[#calls + 1] = { "progress", opts.dirty_only }
                        cb({ pushed = 0 })
                        return { cancel = function() end }
                    end,
                    syncNotesAsync = function(_, opts, cb)
                        calls[#calls + 1] = { "notes", opts.dirty_only }
                        cb({ pushed = 0 })
                        return { cancel = function() end }
                    end,
                    syncStatsAsync = function(_, opts, cb)
                        calls[#calls + 1] = { "stats", opts.dirty_only }
                        cb({ pushed = 0 })
                        return { cancel = function() end }
                    end,
                }, nil
            end,
        }
    end
    package.preload["db.book"] = function()
        return {
            unsynced = function()
                return { { source_id = "moon", stable_id = "b1", deleted = 1 } }
            end,
            markSynced = function()
                error("bookshelf must not blanket markSynced")
            end,
        }
    end
    package.preload["db.progress"] = function()
        return { unsynced = function() return {} end }
    end
    package.preload["db.note"] = function()
        return { unsynced = function() return {} end }
    end
    package.preload["db.stats"] = function()
        return { unsyncedBySource = function() return {} end }
    end
    for _, name in ipairs({
        "book.sync", "source.registry", "db.book", "db.progress", "db.note", "db.stats",
    }) do
        package.loaded[name] = nil
    end
    local Sync2 = require("book.sync")
    Sync2.retryDirtyAsync()
    Stubs.flush()
    Assert.eq(calls[1][1], "books")
    Assert.is_false(calls[1][2], "books 脏时不得 skip_books")
    Assert.is_true(calls[1][3], "books 脏重试必须 dirty_only")
    Assert.is_true(calls[2][2], "progress 强制 dirty_only")
    Assert.is_true(calls[3][2], "notes 强制 dirty_only")
    Assert.is_true(calls[4][2], "stats 继承 dirty_only")
end

package.loaded["book.sync"] = nil
package.loaded["source.registry"] = nil
package.loaded["db.book"] = nil
package.loaded["db.progress"] = nil
package.loaded["db.note"] = nil
package.loaded["db.stats"] = nil
