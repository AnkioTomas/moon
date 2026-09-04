--[[--
book.progress：本地保存与全局未同步队列。

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
local saved = {}
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

package.preload["db.progress"] = function()
    return {
        unsynced = unsynced,
        upsert = function(source_id, stable_id, pos)
            saved[#saved + 1] = { source_id = source_id, stable_id = stable_id, pos = pos }
            rows[#rows + 1] = {
                source_id = source_id,
                stable_id = stable_id,
                fraction = pos.fraction,
                updated_at = pos.updated_at,
                sync_status = 0,
            }
            return true
        end,
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
    return { identityFor = function() return nil end, isCurrentDocument = function() return true end }
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
Stubs.flush()
Assert.len(pushed, 1)
Assert.eq(#marked, 1)
Assert.eq(marked[1][1], "moon")
Assert.eq(marked[1][2], "a.epub")
Assert.eq(rows[1].sync_status, 1)
Assert.eq(rows[2].sync_status, 0)
Assert.eq(rows[3].sync_status, 1)
Assert.eq(sync_result.pushed, 1)
Assert.eq(pulled, 0)

-- 进度保存总是生成一个未同步版本，尚未保存完成时不上传。
local ui = {
    document = { getPageCount = function() return 100 end },
    getCurrentPage = function() return 25 end,
}
local snapshot = {
    ui = ui,
    identity = { source_id = "moon", stable_id = "current.epub", chapter_idx = 3 },
    doc_fraction = 0.25,
}
rows[#rows + 1] = {
    source_id = "moon", stable_id = "current.epub", chapter_idx = 3,
    fraction = 0.2, updated_at = 4, sync_status = 1,
    extra = { chapter_uid = "u3", chapter_idx = 3 },
}
local saved_ok
Progress.save(snapshot, function(ok) saved_ok = ok end)
Assert.is_true(saved_ok)
Assert.len(saved, 1)
Assert.eq(saved[1].pos.fraction, 0.25)
Assert.eq(saved[1].pos.extra.chapter_uid, "u3", "保存同章进度不能清空远端章节 UID")
Assert.is_true(saved[1].pos.updated_at > 0)

Progress.save(snapshot)
Assert.len(saved, 2)
Assert.is_true(saved[2].pos.updated_at > saved[1].pos.updated_at,
    "同一秒连续保存也必须生成不同版本")

for _, name in ipairs({
    "db.progress", "source.registry",
    "ui/widget/infomessage", "ui/event", "book.store", "book.progress",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
