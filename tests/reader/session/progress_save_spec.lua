--[[--
reader.session.progress 保存：每次生成一个更新的未同步版本，同章保留源侧 extra。

@module tests.reader.session.progress_save_spec
--]]

local Assert = require("support.assert")

local rows, saved = {}, {}
package.preload["book.progress_db"] = function()
    return {
        get = function(source_id, stable_id)
            for _idx, row in ipairs(rows) do
                if row.source_id == source_id and row.stable_id == stable_id then return row end
            end
        end,
        upsert = function(source_id, stable_id, pos)
            saved[#saved + 1] = { source_id = source_id, stable_id = stable_id, pos = pos }
            return true
        end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_self, name, ...) return { name = name, args = { ... } } end }
end
package.preload["book.store"] = function()
    return { identityFor = function() return nil end }
end

local ReaderProgress = require("reader.session.progress")

local snapshot = {
    ui = {
        document = { getPageCount = function() return 100 end },
        getCurrentPage = function() return 25 end,
    },
    identity = { source_id = "moon", stable_id = "current.epub", chapter_idx = 3 },
    doc_fraction = 0.25,
}
rows[1] = {
    source_id = "moon", stable_id = "current.epub", chapter_idx = 3,
    fraction = 0.2, updated_at = 4, sync_status = 1,
    extra = { chapter_uid = "u3", chapter_idx = 3 },
}

local saved_ok
ReaderProgress.save(snapshot, function(ok) saved_ok = ok end)
Assert.is_true(saved_ok)
Assert.len(saved, 1)
Assert.eq(saved[1].pos.fraction, 0.25)
Assert.eq(saved[1].pos.extra.chapter_uid, "u3", "保存同章进度不能清空远端章节 UID")
Assert.is_true(saved[1].pos.updated_at > 0)

ReaderProgress.save(snapshot)
Assert.len(saved, 2)
Assert.is_true(saved[2].pos.updated_at > saved[1].pos.updated_at,
    "同一秒连续保存也必须生成不同版本")

-- 身份不全：不写库，回调失败。
local bad_ok
---@diagnostic disable-next-line: missing-fields
ReaderProgress.save({ identity = { source_id = "moon" } }, function(ok) bad_ok = ok end)
Assert.is_false(bad_ok)
Assert.len(saved, 2)

-- ephemeral 源（订阅）不记进度。
local eph_ok
---@diagnostic disable-next-line: missing-fields
ReaderProgress.save({ identity = { source_id = "subscribe", stable_id = "1", source = { ephemeral = true } } },
    function(ok) eph_ok = ok end)
Assert.is_false(eph_ok)
Assert.len(saved, 2)

return true
