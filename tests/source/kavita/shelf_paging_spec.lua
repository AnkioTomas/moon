--[[--
书架分页拉取：并行取页（每次 2 页）后仍能收齐所有 series。

@module tests.source.kavita.shelf_paging_spec
--]]

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

local function makeSeries(from, count)
    local out = {}
    for i = from, from + count - 1 do
        out[#out + 1] = { id = i, name = "B" .. i, libraryName = "L", format = 3, lastChapterAddedUtc = "" }
    end
    return out
end

-- 2500 本 = 首屏满页 1000 + 次组满页 1000 + 尾页 500。
local page_requests = {}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            local url = opts.url or ""
            if url:match("/api/Series/all%-v2") then
                local page = tonumber(url:match("pageNumber=(%d+)")) or 1
                page_requests[#page_requests + 1] = page
                local data
                if page == 1 then data = makeSeries(1, 1000)
                elseif page == 2 then data = makeSeries(1001, 1000)
                elseif page == 3 then data = makeSeries(2001, 500)
                else data = {} end
                cb({ code = 200, body = JsonStub.encode(data) })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local reconciled
package.preload["book.store"] = function()
    return {
        reconcile = function(_, books)
            reconciled = books
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
        shelfStableIds = function() return nil end,
        markDeleted = function() return true end,
        rememberMany = function() end,
    }
end

local Paths = require("utils.paths")
os.remove(Paths.root() .. "/kavita-shelf.json")

local Kavita = require("source.kavita")
local source = Kavita.new()

local result
source:syncBooksAsync({}, function(res) result = res end)

Assert.not_nil(result)
Assert.eq(result.pulled, 2500)
Assert.not_nil(reconciled)
Assert.len(reconciled, 2500)
-- 首屏 1 次 + 并行一组 2 页 = 3 次，无多余探测请求。
Assert.len(page_requests, 3)
Assert.eq(page_requests[1], 1)
Assert.eq(page_requests[2], 2)
Assert.eq(page_requests[3], 3)

os.remove(Paths.root() .. "/kavita-shelf.json")
os.remove(Paths.root() .. "/kavita-backfill.json")
