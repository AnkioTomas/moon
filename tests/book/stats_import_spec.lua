--[[-- book.stats：导入 DocSettings 旧统计并按统计记录去重。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local saved = {}
local rows = {}
local function sameRecord(a, b)
    return a.source_id == b.source_id and a.stable_id == b.stable_id
        and a.page == b.page and a.start_time == b.start_time
        and a.duration == b.duration and a.total_pages == b.total_pages
end
package.preload["utils.db.stats"] = function()
    return {
        allBySource = function(source_id)
            local out = {}
            for _, row in ipairs(rows) do
                if row.source_id == source_id then out[#out + 1] = row end
            end
            return out
        end,
        add = function(row, synced)
            row.sync_status = synced and 1 or 0
            for _, old in ipairs(rows) do
                if sameRecord(old, row) then
                    old.sync_status = math.max(old.sync_status, row.sync_status)
                    return true
                end
            end
            rows[#rows + 1] = row
            saved[#saved + 1] = row
            return true
        end,
    }
end
package.preload["utils.db.book"] = function()
    return {
        pathsAll = function()
            return { { path = "/book.epub", source_id = "local", stable_id = "/book.epub" } }
        end,
        getByMd5 = function() return nil end,
    }
end
package.preload["utils.db.chapter"] = function()
    return { all = function() return {} end }
end
package.preload["docsettings"] = function()
    return {
        open = function(_, path)
            Assert.eq(path, "/book.epub")
            return {
                readSetting = function(_, key)
                    if key == "stats" then
                        return {
                            pages = 100,
                            total_time_in_sec = 30,
                            performance_in_pages = { [1000] = 2, [1010] = 3 },
                        }
                    end
                end,
            }
        end,
    }
end
package.loaded["book.stats"] = nil
package.loaded["utils.db.stats"] = nil
local Stats = require("book.stats")

local result
Stats.importLocalAsync(function(value) result = value end)
Assert.is_nil(result)
Stubs.flush()
Assert.eq(result.imported, 2)
Assert.eq(result.failed, 0)
Assert.eq(#saved, 2)
Assert.eq(saved[1].stable_id, "/book.epub")
Assert.eq(saved[1].duration, 15)
Assert.eq(saved[1].sync_status, 0)

local second
Stats.importLocalAsync(function(value) second = value end)
Stubs.flush()
Assert.eq(second.imported, 0)
Assert.eq(second.skipped, 2)
Assert.eq(#saved, 2)

local pulled
Stats.pull({
    pullStatsAsync = function(_, cb)
        cb({
            { source_id = "local", stable_id = "/book.epub", page = 2, start_time = 1000, duration = 15, total_pages = 100 },
            { source_id = "local", stable_id = "/book.epub", page = 4, start_time = 1020, duration = 10, total_pages = 100 },
        })
    end,
}, function(ok, value)
    pulled = { ok = ok, value = value }
end)
Stubs.flush()
Assert.is_true(pulled.ok)
Assert.eq(pulled.value.imported, 1)
Assert.eq(pulled.value.skipped, 1)
Assert.eq(#saved, 3)
Assert.eq(saved[3].sync_status, 1, "pull 记录必须直接标记为已同步")
Assert.eq(rows[1].sync_status, 1, "pull 命中本地重复记录时必须确认其同步状态")
