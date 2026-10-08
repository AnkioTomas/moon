--[[--
书架增量刷新：快照（库集合 + 每本指纹）与本地集合都未变时跳过对账；
任一 series 变化（新增/删除/改名/漫画进度）则重跑对账，且漫画只回填变化的那本。

@module tests.source.kavita.incremental_shelf_spec
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

local series_payload = {
    { id = 1, name = "A", libraryName = "L", format = 3, lastChapterAddedUtc = "t1" },
    { id = 2, name = "B", libraryName = "L", format = 3, lastChapterAddedUtc = "t2" },
    { id = 3, name = "C", libraryName = "L", format = 3, lastChapterAddedUtc = "t3" },
    { id = 4, name = "Comic", libraryName = "M", format = 1, pages = 100, pagesRead = 10, latestReadDate = "d1", lastChapterAddedUtc = "t4" },
}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            local url = opts.url or ""
            if url:match("/api/Series/all%-v2") then
                local page = tonumber(url:match("pageNumber=(%d+)")) or 1
                cb({ code = 200, body = JsonStub.encode(page == 1 and series_payload or {}) })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local reconcile_calls = 0
local delta_calls = {}
package.preload["book.store"] = function()
    return {
        reconcile = function(_, books)
            reconcile_calls = reconcile_calls + 1
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
        reconcileDelta = function(_, changed, removed)
            delta_calls[#delta_calls + 1] = { changed = changed, removed = removed }
            return { pulled = #changed, pushed = 0, hidden = #removed, conflicts = 0, skipped = false }
        end,
        -- 本地集合跟随当前远端集合（模拟每次对账后已入库）。
        shelfStableIds = function()
            local ids = {}
            for _, s in ipairs(series_payload) do ids[#ids + 1] = tostring(s.id) end
            return ids
        end,
        markDeleted = function() return true end,
        rememberMany = function() end,
    }
end

local progress_writes = {}
package.preload["db.progress"] = function()
    return {
        upsertRemote = function(source_id, stable_id, pos)
            progress_writes[#progress_writes + 1] = { source_id = source_id, stable_id = stable_id, pos = pos }
            return true
        end,
    }
end

local Paths = require("utils.paths")
local shelf_state = Paths.root() .. "/kavita-shelf.json"
local backfill_state = Paths.root() .. "/kavita-backfill.json"
os.remove(shelf_state)
-- 预置补全状态，避免本用例触发元数据拉取。
local file = io.open(backfill_state, "w")
if file then file:write('{"1":"t1","2":"t2","3":"t3","4":"t4"}'); file:close() end

local Kavita = require("source.kavita")
local source = Kavita.new()

local function sync()
    local result
    source:syncBooksAsync({}, function(res) result = res end)
    return result
end

-- 首次：无快照 → 全量对账 + 落快照，漫画进度全量回填。
local first = sync()
Assert.not_nil(first)
Assert.is_false(first.skipped)
Assert.eq(reconcile_calls, 1)
Assert.len(delta_calls, 0)
Assert.len(progress_writes, 1)
Assert.eq(progress_writes[1].stable_id, "4")

-- 第二次：完全没变 → 跳过对账（但仍报 unchanged，让上层刷新本地进度），不再回填漫画进度。
local second = sync()
Assert.is_false(second.skipped)
Assert.is_true(second.unchanged)
Assert.eq(reconcile_calls, 1)
Assert.len(progress_writes, 1)

-- 书籍改名 → 只增量写该行，漫画进度不受影响（未变不回填）。
series_payload[1].name = "A renamed"
Assert.is_false(sync().skipped)
Assert.eq(reconcile_calls, 1)
Assert.len(delta_calls, 1)
Assert.len(delta_calls[1].changed, 1)
Assert.eq(delta_calls[1].changed[1].stable_id, "1")
Assert.len(delta_calls[1].removed, 0)
Assert.len(progress_writes, 1)

-- 漫画进度变化 → 只增量写该漫画，并只回填它。
series_payload[4].pagesRead = 50
series_payload[4].latestReadDate = "d2"
Assert.is_false(sync().skipped)
Assert.len(delta_calls, 2)
Assert.eq(delta_calls[2].changed[1].stable_id, "4")
Assert.len(progress_writes, 2)
Assert.eq(progress_writes[2].stable_id, "4")
Assert.eq(progress_writes[2].pos.page, 50)

-- 远端删除一本 → 只把该本标软删。
series_payload = { series_payload[1], series_payload[3], series_payload[4] }
Assert.is_false(sync().skipped)
Assert.len(delta_calls, 3)
Assert.len(delta_calls[3].changed, 0)
Assert.len(delta_calls[3].removed, 1)
Assert.eq(delta_calls[3].removed[1], "2")

-- 再同步一次无变化 → 又跳过。
Assert.is_true(sync().unchanged)
Assert.len(delta_calls, 3)

os.remove(shelf_state)
os.remove(backfill_state)
