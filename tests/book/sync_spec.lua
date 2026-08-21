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

package.loaded["book.sync"] = nil
