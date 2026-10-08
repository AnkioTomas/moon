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
local adopted = {}
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
        adoptRemote = function(source_id, stable_id, pos)
            adopted[#adopted + 1] = { source_id = source_id, stable_id = stable_id, pos = pos }
            for _, row in ipairs(rows) do
                if row.source_id == source_id and row.stable_id == stable_id then row.sync_status = 1 end
            end
            return true
        end,
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
        -- 与本地一致 → 不冲突，直接推。
        cb({ fraction = 0.4 })
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

-- 批量 dirty_only：先拉云端比对（一致就直接推），上传成功按版本确认。
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
Assert.eq(pulled, 1, "批量同步推之前先拉云端比对")

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

-- 重连冲突：批量同步发现本地脏 vs 云端不同 → 弹窗；选云端采纳远端，选本地回推。
do
    local q = {}
    local ui = {}
    ui.nextTick = function(_, fn) q[#q + 1] = fn end
    ui.scheduleIn = function(_, _, fn) q[#q + 1] = fn end
    ui.unschedule = function() end
    ui.show = function(_, w) ui.widget = w end
    ui.close = function() end
    ui.setDirty = function() end
    local function flush()
        while #q > 0 do
            local fn = table.remove(q, 1)
            fn()
        end
    end
    package.loaded["ui/uimanager"] = ui
    package.loaded["ui/widget/confirmbox"] = { new = function(_, opts) return opts end }
    -- 冲突弹窗只对「当前正在阅读的那本」弹：用 current() 模拟当前打开的书。
    local open_identity = nil
    package.preload["ui.reader.session"] = function()
        return { current = function() return open_identity and { identity = open_identity } or nil end }
    end
    package.loaded["ui.reader.session"] = nil

    local pushed = {}
    local function conflict_source(id)
        return {
            id = id,
            putProgressAsync = function(_, _, pos, cb)
                pushed[id] = (pushed[id] or 0) + 1
                cb(true)
                return { cancel = function() end }
            end,
            getProgressAsync = function(_, _, cb)
                cb({ fraction = 0.2, page = 2, total_pages = 100 })
                return { cancel = function() end }
            end,
        }
    end

    -- 选云端（ok）：采纳远端、不推。
    open_identity = { source_id = "conf-cloud", stable_id = "x.epub" }
    rows[#rows + 1] = { source_id = "conf-cloud", stable_id = "x.epub", fraction = 0.9, page = 90, total_pages = 100, updated_at = 51, sync_status = 0 }
    local done
    Progress.syncAsync(conflict_source("conf-cloud"), { dirty_only = true }, function() done = true end)
    flush()
    Assert.not_nil(ui.widget, "本地/云端不一致应弹窗")
    Assert.is_true(tostring(ui.widget.text):find("保留哪个", 1, true) ~= nil)
    Assert.len(adopted, 0)
    ui.widget.ok_callback()
    flush()
    Assert.len(adopted, 1)
    Assert.eq(adopted[1].stable_id, "x.epub")
    Assert.eq(adopted[1].pos.fraction, 0.2)
    Assert.is_nil(pushed["conf-cloud"])
    Assert.is_true(done)

    -- 选本地（cancel）：回推本地。
    ui.widget = nil
    open_identity = { source_id = "conf-local", stable_id = "y.epub" }
    rows[#rows + 1] = { source_id = "conf-local", stable_id = "y.epub", fraction = 0.8, page = 80, total_pages = 100, updated_at = 52, sync_status = 0 }
    local done2
    Progress.syncAsync(conflict_source("conf-local"), { dirty_only = true }, function() done2 = true end)
    flush()
    Assert.not_nil(ui.widget)
    ui.widget.cancel_callback()
    flush()
    Assert.eq(pushed["conf-local"], 1)
    Assert.is_true(done2)

    -- 页数单位不同（Kavita spine vs 内容页）→ 两侧按 DocFragment 序号对齐，单位一致。
    ui.widget = nil
    open_identity = { source_id = "conf-spine", stable_id = "z.epub" }
    rows[#rows + 1] = {
        source_id = "conf-spine", stable_id = "z.epub", fraction = 0.65,
        page = 250, total_pages = 380, updated_at = 53, sync_status = 0,
        locator = "/body/DocFragment[22]/body/p[1]/text().0",
    }
    local spine_source = {
        id = "conf-spine",
        putProgressAsync = function(_, _, _, cb) cb(true); return { cancel = function() end } end,
        getProgressAsync = function(_, _, cb)
            cb({
                fraction = 0.15, page = 21, total_pages = 137,
                locator = "/body/DocFragment[21]/body/p[3]/text().0",
            })
            return { cancel = function() end }
        end,
    }
    local done3
    Progress.syncAsync(spine_source, { dirty_only = true }, function() done3 = true end)
    flush()
    Assert.not_nil(ui.widget)
    Assert.is_true(tostring(ui.widget.text):find("第 22 / 137 页", 1, true) ~= nil, "本地按 spine 对齐")
    Assert.is_true(tostring(ui.widget.text):find("第 21 / 137 页", 1, true) ~= nil, "云端按 spine 对齐")
    ui.widget.ok_callback()
    flush()
    Assert.is_true(done3)

    -- 一轮最多弹一次，且只对「当前在读」的那本弹；其余冲突留脏不推（不覆盖云端）。
    ui.widget = nil
    open_identity = { source_id = "conf-multi", stable_id = "a.epub" }
    rows[#rows + 1] = { source_id = "conf-multi", stable_id = "a.epub", fraction = 0.9, page = 90, total_pages = 100, updated_at = 61, sync_status = 0 }
    rows[#rows + 1] = { source_id = "conf-multi", stable_id = "b.epub", fraction = 0.9, page = 90, total_pages = 100, updated_at = 62, sync_status = 0 }
    local multi_pushed = {}
    local multi_source = {
        id = "conf-multi",
        putProgressAsync = function(_, identity, _, cb)
            multi_pushed[identity.stable_id] = (multi_pushed[identity.stable_id] or 0) + 1
            cb(true)
            return { cancel = function() end }
        end,
        getProgressAsync = function(_, _, cb)
            cb({ fraction = 0.2, page = 2, total_pages = 100 })
            return { cancel = function() end }
        end,
    }
    local done4
    Progress.syncAsync(multi_source, { dirty_only = true }, function() done4 = true end)
    flush()
    Assert.not_nil(ui.widget, "当前在读的冲突弹窗")
    ui.widget.cancel_callback()
    ui.widget = nil
    flush()
    Assert.eq(multi_pushed["a.epub"], 1, "当前在读的冲突按用户选择回推")
    Assert.is_nil(multi_pushed["b.epub"], "非当前在读的冲突留脏，不弹也不推、不覆盖云端")
    Assert.is_true(done4)

    -- 关书推送（identity/silent）：云端更靠后 → 当场弹窗让用户选，不推本地也不静默采纳
    ui.widget = nil
    open_identity = { source_id = "conf-close", stable_id = "c.epub" }
    rows[#rows + 1] = { source_id = "conf-close", stable_id = "c.epub", fraction = 0.2, updated_at = 71, sync_status = 0, locator = "/body/DocFragment[5]/body/p[1]" }
    local close_pushed = 0
    local close_source = {
        id = "conf-close",
        putProgressAsync = function(_, _, _, cb) close_pushed = close_pushed + 1; cb(true); return { cancel = function() end } end,
        getProgressAsync = function(_, _, cb)
            cb({ fraction = 0.6, page = 20, total_pages = 33, locator = "/body/DocFragment[21]/body/p[1]" }, nil, { page_level = true })
            return { cancel = function() end }
        end,
    }
    local adopted_before = #adopted
    Progress.syncAsync(close_source, { identity = { source_id = "conf-close", stable_id = "c.epub" }, dirty_only = true }, function() end)
    flush()
    Assert.not_nil(ui.widget, "云端更靠后关书当场弹窗")
    Assert.eq(close_pushed, 0, "弹窗未决议前不推本地")
    Assert.eq(#adopted - adopted_before, 0, "弹窗未决议前不采纳云端")
    ui.widget.cancel_callback() -- 选「本地」
    ui.widget = nil
    flush()
    Assert.eq(close_pushed, 1, "选本地则关书回推本地")

    -- 关书推送：本地不落后 → 推本地
    open_identity = { source_id = "conf-close2", stable_id = "d.epub" }
    rows[#rows + 1] = { source_id = "conf-close2", stable_id = "d.epub", fraction = 0.9, updated_at = 72, sync_status = 0, locator = "/body/DocFragment[21]/body/p[1]" }
    local pushed2 = 0
    local close_source2 = {
        id = "conf-close2",
        putProgressAsync = function(_, _, _, cb) pushed2 = pushed2 + 1; cb(true); return { cancel = function() end } end,
        getProgressAsync = function(_, _, cb)
            cb({ fraction = 0.2, page = 5, total_pages = 33, locator = "/body/DocFragment[5]/body/p[1]" }, nil, { page_level = true })
            return { cancel = function() end }
        end,
    }
    Progress.syncAsync(close_source2, { identity = { source_id = "conf-close2", stable_id = "d.epub" }, dirty_only = true }, function() end)
    flush()
    Assert.eq(pushed2, 1, "本地不落后推本地")

    -- 关书推送：同 spine 内云端元素更靠后不算「云端更靠后」（视口取整噪声）→ 直接推本地，
    -- 不再弹窗。复现「选云端跳转后立刻关书又报进度不一致」。
    ui.widget = nil
    open_identity = { source_id = "conf-close3", stable_id = "f.epub" }
    rows[#rows + 1] = {
        source_id = "conf-close3", stable_id = "f.epub", fraction = 0.45, updated_at = 74,
        sync_status = 0, locator = "/body[1]/DocFragment[13]/body[1]/p[3]/text()[1].0",
    }
    local pushed3 = 0
    local close_source3 = {
        id = "conf-close3",
        putProgressAsync = function(_, _, _, cb) pushed3 = pushed3 + 1; cb(true); return { cancel = function() end } end,
        getProgressAsync = function(_, _, cb)
            cb({ fraction = 0.55, page = 13, total_pages = 33,
                locator = "/body/DocFragment[13]/body/p[9]" }, nil, { page_level = true })
            return { cancel = function() end }
        end,
    }
    Progress.syncAsync(close_source3, { identity = { source_id = "conf-close3", stable_id = "f.epub" }, dirty_only = true }, function() end)
    flush()
    Assert.is_nil(ui.widget, "同 spine 元素级靠后不应弹假冲突")
    Assert.eq(pushed3, 1, "同 spine 直接推本地收敛")

    -- 关书推送：同 spine 但云端已读完 → 仍弹窗（推本地会让远端退回未完成）
    ui.widget = nil
    open_identity = { source_id = "conf-close4", stable_id = "g.epub" }
    rows[#rows + 1] = {
        source_id = "conf-close4", stable_id = "g.epub", fraction = 0.45, updated_at = 75,
        sync_status = 0, locator = "/body/DocFragment[13]/body/p[3]",
    }
    local pushed4 = 0
    local close_source4 = {
        id = "conf-close4",
        putProgressAsync = function(_, _, _, cb) pushed4 = pushed4 + 1; cb(true); return { cancel = function() end } end,
        getProgressAsync = function(_, _, cb)
            cb({ fraction = 1, page = 33, total_pages = 33,
                locator = "/body/DocFragment[13]/body/p[9]" }, nil, { page_level = true })
            return { cancel = function() end }
        end,
    }
    Progress.syncAsync(close_source4, { identity = { source_id = "conf-close4", stable_id = "g.epub" }, dirty_only = true }, function() end)
    flush()
    Assert.not_nil(ui.widget, "同 spine 云端已读完仍要弹窗")
    Assert.eq(pushed4, 0, "弹窗未决议前不推本地")

    -- force（用户在冲突弹窗里选了「本地」）：跳过比对直接推本地，即使云端更靠后
    open_identity = { source_id = "conf-force", stable_id = "e.epub" }
    rows[#rows + 1] = { source_id = "conf-force", stable_id = "e.epub", fraction = 0.2, updated_at = 73, sync_status = 0, locator = "/body/DocFragment[5]/body/p[1]" }
    local force_pushed, force_get = 0, 0
    local force_source = {
        id = "conf-force",
        putProgressAsync = function(_, _, _, cb) force_pushed = force_pushed + 1; cb(true); return { cancel = function() end } end,
        getProgressAsync = function(_, _, cb)
            force_get = force_get + 1
            cb({ fraction = 0.6, page = 20, total_pages = 33, locator = "/body/DocFragment[21]/body/p[1]" }, nil, { page_level = true })
            return { cancel = function() end }
        end,
    }
    Progress.syncAsync(force_source, {
        identity = { source_id = "conf-force", stable_id = "e.epub" }, dirty_only = true, force = true,
    }, function() end)
    flush()
    Assert.eq(force_get, 0, "force 不拉云端比对")
    Assert.eq(force_pushed, 1, "force 直接推本地盖云端")
end

for _, name in ipairs({
    "db.progress", "source.registry",
    "ui/widget/infomessage", "ui/event", "book.store", "book.progress",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
