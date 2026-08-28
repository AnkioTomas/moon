--[[-- book.stats：导入 DocSettings 旧统计并按统计记录去重。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local saved = {}
local rows = {}
local deleted_synced = 0
local function sameRecord(a, b)
    return a.source_id == b.source_id and a.stable_id == b.stable_id
        and a.page == b.page and a.start_time == b.start_time
        and a.duration == b.duration and a.total_pages == b.total_pages
end
local StatsDBStub
local replace_fails = false
package.preload["utils.db.stats"] = function()
    StatsDBStub = StatsDBStub or {
        exists = function(row)
            for _, old in ipairs(rows) do
                if sameRecord(old, row) then return true end
            end
            return false
        end,
        replaceSynced = function(source_id, replace, incoming)
            if replace_fails then return nil end
            if type(replace) == "table" then
                StatsDBStub.deleteSyncedBySource(source_id)
            end
            local result = { imported = 0, skipped = 0 }
            for _, row in ipairs(incoming) do
                if StatsDBStub.exists(row) then
                    result.skipped = result.skipped + 1
                else
                    result.imported = result.imported + 1
                end
                StatsDBStub.add(row, true)
            end
            return result
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
        deleteSyncedBySource = function(source_id)
            local kept = {}
            for _, row in ipairs(rows) do
                if row.source_id == source_id and row.sync_status == 1 then
                    deleted_synced = deleted_synced + 1
                else
                    kept[#kept + 1] = row
                end
            end
            rows = kept
            return true
        end,
        deleteSyncedByStablePrefix = function() return true end,
        summaryBySource = function() return { total_seconds = 0 } end,
        unsyncedBySource = function() return {} end,
    }
    return StatsDBStub
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

deleted_synced = 0
rows[#rows + 1] = {
    source_id = "wechat", stable_id = "__wr:day:1", page = 0,
    start_time = 1, duration = 10, total_pages = 0, sync_status = 1,
}
local replaced
Stats.pull({
    id = "wechat",
    configured = function() return true end,
    capabilities = function() return { stats_pull = true } end,
    pullStatsAsync = function(_, cb)
        cb({
            rows = {
                { source_id = "wechat", stable_id = "__wr:day:1000", page = 0, start_time = 1000, duration = 99, total_pages = 0 },
            },
            replace = { mode = "synced" },
        })
    end,
}, function(ok, value)
    replaced = { ok = ok, value = value }
end)
Stubs.flush()
Assert.is_true(replaced.ok)
Assert.eq(deleted_synced, 1)
local wechat_rows = 0
for _, row in ipairs(rows) do
    if row.source_id == "wechat" then
        wechat_rows = wechat_rows + 1
        Assert.eq(row.stable_id, "__wr:day:1000")
        Assert.eq(row.duration, 99)
    end
end
Assert.eq(wechat_rows, 1)

-- ── syncStatsAsync 必须与 Stats.pull 走同一条解析：{ rows, replace } 回包要真入库 ──
deleted_synced = 0
local synced
Stats.syncAsync({
    id = "wechat",
    configured = function() return true end,
    capabilities = function() return { stats_pull = true } end,
    pullStatsAsync = function(_, cb)
        cb({
            rows = {
                { source_id = "wechat", stable_id = "__wr:day:2000", page = 0, start_time = 2000, duration = 42, total_pages = 0 },
            },
            replace = { mode = "synced" },
        })
    end,
}, nil, function(value, err) synced = { value = value, err = err } end)
Stubs.flush()
Assert.eq(synced.err, nil)
Assert.eq(synced.value.pulled, 1, "syncStatsAsync 必须解开 { rows, replace } 回包")
Assert.eq(deleted_synced, 1, "syncStatsAsync 不能绕过 replace 策略")

-- ── pull 落库失败：整批回滚，不留下「删了旧的又没写新的」的空窗 ──
replace_fails = true
local broken
Stats.pull({
    id = "wechat",
    pullStatsAsync = function(_, cb) cb({ rows = {}, replace = { mode = "synced" } }) end,
}, function(ok, value) broken = { ok = ok, value = value } end)
Stubs.flush()
replace_fails = false
Assert.is_false(broken.ok, "落库失败必须向上报错，不能静默成功")
