local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local JsonStub = require("support.json_stub")
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["8"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local http_requests = {}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            http_requests[#http_requests + 1] = opts
            local url = opts.url or ""
            if url:match("/api/Series/all%-v2") then
                local page = tonumber(url:match("pageNumber=(%d+)")) or 1
                if page == 1 then
                    cb({ code = 200, body = '[{"id":1,"name":"Book A","libraryName":"书籍","format":3},{"id":2,"name":"Book B","libraryName":"书籍","format":4}]' })
                else
                    cb({ code = 200, body = '[]' })
                end
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local reconcile_calls = {}
package.preload["book.store"] = function()
    return {
        reconcile = function(source_id, books)
            reconcile_calls[#reconcile_calls + 1] = { source_id = source_id, books = books }
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
        markDeleted = function(source_id, stable_id)
            return true
        end,
    }
end

local Kavita = require("source.kavita")
local source = Kavita.new()

local result
source:syncBooksAsync({}, function(res, err)
    result = res
end)

Assert.not_nil(result)
Assert.eq(result.pulled, 2)
Assert.eq(result.skipped, false)
Assert.len(reconcile_calls, 1)
Assert.eq(reconcile_calls[1].source_id, "kavita")
Assert.eq(#reconcile_calls[1].books, 2)
Assert.eq(reconcile_calls[1].books[1].stable_id, "1")
Assert.eq(reconcile_calls[1].books[1].title, "Book A")
Assert.eq(reconcile_calls[1].books[1].category, "书籍")
Assert.eq(reconcile_calls[1].books[1].format, "epub")
Assert.eq(reconcile_calls[1].books[2].stable_id, "2")
Assert.eq(reconcile_calls[1].books[2].format, "pdf")

local delete_result
source:deleteBookAsync({ source_id = "kavita", stable_id = "1" }, function(ok, err)
    delete_result = ok
end)

Assert.is_true(delete_result)

local dirty_result
source:syncBooksAsync({ dirty_only = true }, function(res, err)
    dirty_result = res
end)

Assert.not_nil(dirty_result)
Assert.is_true(dirty_result.skipped)
Assert.eq(dirty_result.reason, "kavita dirty_only no-op")
Assert.len(reconcile_calls, 1)

local empty_cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = {} }
cfg = empty_cfg
source = Kavita.new()
local empty_result
source:syncBooksAsync({}, function(res, err)
    empty_result = res
end)

Assert.not_nil(empty_result)
Assert.is_true(empty_result.skipped)
Assert.len(reconcile_calls, 1)
