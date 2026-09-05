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
        unsyncedBySource = function(_, limit)
            local rows = {}
            for i = 1, math.min(#pending, limit or #pending) do rows[i] = pending[i] end
            return rows
        end,
        markSynced = function(ids)
            local remove = {}
            for _, id in ipairs(ids) do remove[id] = true end
            local left = {}
            for _, row in ipairs(pending) do
                if not remove[row.id] then left[#left + 1] = row end
            end
            pending = left
            return true
        end,
        compactSynced = function() return 0 end,
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
        Assert.eq(#rows, #pending)
        Assert.eq(rows[1].id, pending[1].id)
        cb({ synced_ids = { rows[1].id } })
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
pending = {
    {
        id = 2, source_id = "wechat", stable_id = "book-1",
        record_type = "page", page = 2, start_time = 1100, duration = 60, total_pages = 10,
    },
}
Stats.syncAsync(source, { dirty_only = true }, function(value) result = value end)
Assert.eq(table.concat(order, ","), "push")
Assert.eq(result.pushed, 1)
Assert.eq(result.pulled, 0)

-- 大队列必须分批上传，不能一次把全部记录和请求体留在内存。
order, result = {}, nil
pending = {}
for i = 1, 201 do
    pending[i] = {
        id = 1000 + i, source_id = "wechat", stable_id = "book-1",
        record_type = "page", page = i, start_time = 2000 + i,
        duration = 1, total_pages = 300,
    }
end
local batch_sizes = {}
source.pushStatsAsync = function(_, rows, cb)
    order[#order + 1] = "push"
    batch_sizes[#batch_sizes + 1] = #rows
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = row.id end
    cb({ synced_ids = ids })
end
Stats.syncAsync(source, nil, function(value) result = value end)
Assert.eq(batch_sizes[1], 200)
Assert.eq(batch_sizes[2], 1)
Assert.eq(result.pushed, 201)
Assert.eq(result.pulled, 1)

-- 上报失败不能阻断远端拉取；本地脏记录仍保留，后续继续重试。
order, result = {}, nil
pending = {
    {
        id = 3, source_id = "wechat", stable_id = "book-1",
        record_type = "page", page = 3, start_time = 1200, duration = 60, total_pages = 10,
    },
}
source.pushStatsAsync = function(_, _, cb)
    order[#order + 1] = "push"
    cb(nil, "upload failed")
end
Stats.syncAsync(source, nil, function(value) result = value end)
Assert.eq(table.concat(order, ","), "push,pull")
Assert.eq(result.pushed, 0)
Assert.eq(result.pulled, 1)
Assert.eq(result.push_error, "upload failed")

