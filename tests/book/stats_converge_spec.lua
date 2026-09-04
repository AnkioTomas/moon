--[[-- book.stats：生命周期同步先推本地脏数据，再拉远端聚合落库。 --]]

local Assert = require("support.assert")

local pending = {
    {
        id = 1,
        source_id = "wechat",
        stable_id = "book-1",
        record_type = "page",
        page = 1,
        start_time = 1000,
        duration = 60,
        total_pages = 10,
    },
}
package.preload["db.stats"] = function()
    return {
        unsyncedBySource = function() return pending end,
        markSynced = function() return true end,
        replaceSynced = function(_, _, rows)
            return { imported = #rows, skipped = 0 }
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, fn) fn() end }
end

package.loaded["book.stats"] = nil
local Stats = require("book.stats")

local order = {}
local source = {
    id = "wechat",
    capabilities = function() return { stats_pull = true } end,
    pushStatsAsync = function(_, rows, cb)
        order[#order + 1] = "push"
        Assert.eq(rows, pending)
        cb({ synced_ids = { 1 } })
    end,
    pullStatsAsync = function(_, cb)
        order[#order + 1] = "pull"
        cb({
            {
                source_id = "wechat",
                stable_id = "__wr:day:1000",
                record_type = "day",
                start_time = 1000,
                duration = 120,
            },
        })
    end,
}

local result
Stats.syncAsync(source, nil, function(value) result = value end)
Assert.eq(table.concat(order, ","), "push,pull")
Assert.eq(result.pushed, 1)
Assert.eq(result.pulled, 1)

order, result = {}, nil
Stats.syncAsync(source, { dirty_only = true }, function(value) result = value end)
Assert.eq(table.concat(order, ","), "push")
Assert.eq(result.pushed, 1)
Assert.eq(result.pulled, 0)

-- 上报失败不能阻断远端拉取；本地脏记录仍保留，后续继续重试。
order, result = {}, nil
source.pushStatsAsync = function(_, _, cb)
    order[#order + 1] = "push"
    cb(nil, "upload failed")
end
Stats.syncAsync(source, nil, function(value) result = value end)
Assert.eq(table.concat(order, ","), "push,pull")
Assert.eq(result.pushed, 0)
Assert.eq(result.pulled, 1)
Assert.eq(result.push_error, "upload failed")

