--[[--
book.progress：全局未同步队列上行与修订号。

@module tests.book.progress_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local rows = {
    { source_id = "moon", stable_id = "a.epub", fraction = 0.4, updated_at = 1, sync_status = 0 },
    { source_id = "wechat", stable_id = "b.epub", fraction = 0.9, updated_at = 2, sync_status = 0 },
    { source_id = "moon", stable_id = "done.epub", fraction = 0.2, updated_at = 3, sync_status = 1 },
}
local marked = {}
local sources = {}

local function unsynced(source_id)
    local out = {}
    for _, row in ipairs(rows) do
        if row.sync_status == 0 and (not source_id or row.source_id == source_id) then
            out[#out + 1] = row
        end
    end
    return out
end

package.preload["book.progress_db"] = function()
    return {
        unsynced = unsynced,
        markSynced = function(source_id, stable_id, updated_at)
            marked[#marked + 1] = { source_id, stable_id, updated_at }
            for _, row in ipairs(rows) do
                if row.source_id == source_id and row.stable_id == stable_id and row.updated_at == updated_at then
                    row.sync_status = 1
                end
            end
            return true
        end,
        get = function(source_id, stable_id)
            for _, row in ipairs(rows) do
                if row.source_id == source_id and row.stable_id == stable_id then return row end
            end
        end,
        upsertRemote = function() return true end,
    }
end


package.preload["source.registry"] = function()
    return { resolve = function(id) return sources[id] end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, ...) return { name = name, args = { ... } } end }
end
package.preload["book.store"] = function()
    return { identityFor = function() return nil end }
end

package.loaded["book.progress"] = nil
local Progress = require("book.progress")

local pushed = {}
local pulled = 0
sources.moon = {
    id = "moon",
    putProgressAsync = function(_, identity, pos, cb)
        pushed[#pushed + 1] = { "moon", identity.stable_id, pos.fraction }
        cb(true)
        return { cancel = function() end }
    end,
    getProgressAsync = function(_, _, cb)
        pulled = pulled + 1
        cb({ fraction = 0.1 })
        return { cancel = function() end }
    end,
}
sources.wechat = {
    id = "wechat",
    putProgressAsync = function(_, identity, pos, cb)
        pushed[#pushed + 1] = { "wechat", identity.stable_id, pos.fraction }
        cb(nil, "offline")
        return { cancel = function() end }
    end,
}

-- dirty_only 只处理指定源的本地脏项，上传成功按版本确认，绝不拉远端。
local sync_result
Progress.syncAsync(sources.moon, { dirty_only = true }, function(result) sync_result = result end)
local duplicate_result
Progress.syncAsync(sources.moon, { dirty_only = true }, function(result) duplicate_result = result end)
Stubs.flush()
Assert.len(pushed, 1)
Assert.eq(#marked, 1)
Assert.eq(marked[1][1], "moon")
Assert.eq(marked[1][2], "a.epub")
Assert.eq(rows[1].sync_status, 1)
Assert.eq(rows[2].sync_status, 0)
Assert.eq(rows[3].sync_status, 1)
Assert.eq(sync_result.pushed, 1)
Assert.eq(duplicate_result, sync_result)
Assert.eq(pulled, 0)

-- 单个订阅取消不影响共享任务；全部取消才取消底层，之后同 key 可重新启动。
rows[#rows + 1] = {
    source_id = "cancel", stable_id = "c.epub", fraction = 0.3,
    updated_at = 30, sync_status = 0,
}
local starts, cancels, callbacks = 0, 0, {}
local cancel_source = {
    id = "cancel",
    putProgressAsync = function(_, _, _, cb)
        starts = starts + 1
        callbacks[#callbacks + 1] = cb
        return { cancel = function() cancels = cancels + 1 end }
    end,
}
local first = Progress.syncAsync(cancel_source, { dirty_only = true })
local second = Progress.syncAsync(cancel_source, { dirty_only = true })
Stubs.flush()
Assert.eq(starts, 1)
first.cancel()
Assert.eq(cancels, 0)
second.cancel()
Assert.eq(cancels, 1)

local restarted
Progress.syncAsync(cancel_source, { dirty_only = true }, function(result) restarted = result end)
Stubs.flush()
Assert.eq(starts, 2)
callbacks[2](true)
Assert.eq(restarted.pushed, 1)

-- 全量同步：永久失败的行标为已同步丢弃；单本暂时失败不中止，其余照推，最后整体报失败。
do
    for _, id in ipairs({ "m1", "m2", "m3" }) do
        rows[#rows + 1] = { source_id = "multi", stable_id = id, fraction = 0.5, updated_at = 40, sync_status = 0 }
    end
    local tried = {}
    local multi = {
        id = "multi",
        putProgressAsync = function(_, identity, _, cb)
            tried[#tried + 1] = identity.stable_id
            if identity.stable_id == "m1" then cb(nil, "缺少章节信息", { permanent = true })
            elseif identity.stable_id == "m2" then cb(nil, "offline")
            else cb(true) end
            return { cancel = function() end }
        end,
    }
    local res, err
    Progress.syncAsync(multi, {}, function(r, e) res, err = r, e end)
    Stubs.flush()
    Assert.eq(table.concat(tried, ","), "m1,m2,m3", "单本失败不中止整次同步")
    Assert.is_nil(res)
    Assert.eq(err, "offline")
    local status = {}
    for _, row in ipairs(rows) do if row.source_id == "multi" then status[row.stable_id] = row.sync_status end end
    Assert.eq(status.m1, 1, "永久失败的行不再重试")
    Assert.eq(status.m2, 0)
    Assert.eq(status.m3, 1)
end

-- 修订号严格递增：同一秒连续取号也不重复。
local r1 = Progress.nextRevision()
Assert.is_true(Progress.nextRevision() > r1)

for _, name in ipairs({
    "book.progress_db", "source.registry",
    "ui/widget/infomessage", "ui/event", "book.store", "book.progress",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
