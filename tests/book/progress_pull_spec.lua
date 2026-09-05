--[[--
book.progress pull：开书后先拉远端再对比，冲突时不应先推脏本地。

@module tests.book.progress_pull_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local shown = {}
local synced = {}
local upserted = {}
local remote_upserted = {}
local remote_adopted = {}
local pulled = 0
local pending_row
local current_ui = {}
local current_identity = {
    source_id = "wechat",
    stable_id = "b1",
    chapter_idx = 3,
    source = nil,
}

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        nextTick = function(fn) fn() end,
    }
end
package.loaded["ui/uimanager"] = nil
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, ...) return { name = name, args = { ... } } end }
end
package.preload["ui.reader.session.toc"] = function()
    return {
        list = function() return { {}, {}, {}, {}, {} } end,
        chapterFraction = function() return 0 end,
    }
end
package.preload["ui.reader.session"] = function()
    return {
        isCurrent = function(id)
            return id
                and id.source_id == current_identity.source_id
                and id.stable_id == current_identity.stable_id
                and id.chapter_idx == current_identity.chapter_idx
        end,
        current = function()
            return {
                identity = current_identity,
                ui = current_ui,
                doc_fraction = 0,
            }
        end,
        chapterTitle = function() return "" end,
        gotoChapter = function() return false end,
    }
end
package.loaded["ui.reader.session"] = nil
package.loaded["ui.reader.session.toc"] = nil
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end
package.preload["db.progress"] = function()
    return {
        get = function(_, stable_id)
            if stable_id == "b1" then
                return pending_row
            end
        end,
        upsert = function(_, _, pos) upserted[#upserted + 1] = pos; return true end,
        upsertRemote = function(_, _, pos)
            remote_upserted[#remote_upserted + 1] = pos
            return true
        end,
        adoptRemote = function(_, _, pos)
            remote_adopted[#remote_adopted + 1] = pos
            return true
        end,
    }
end

local source = {
    id = "wechat",
    type = "chapter",
    getProgressAsync = function(_, _, cb)
        pulled = pulled + 1
        cb({
            fraction = 0.8,
            chapter_idx = 8,
            chapter_fraction = 0.2,
        })
        return { cancel = function() end }
    end,
    syncProgressAsync = function(_, opts, cb)
        synced[#synced + 1] = opts.identity and opts.identity.stable_id
        synced.dirty_only = opts.dirty_only
        if cb then cb({ pulled = 0, pushed = 0 }) end
        return { cancel = function() end }
    end,
}
current_identity.source = source

local function snapshot()
    return {
        identity = current_identity,
        ui = current_ui,
        doc_fraction = 0,
    }
end

package.loaded["book.progress"] = nil
local Progress = require("book.progress")
local Session = require("ui.reader.session")

Assert.is_true(Session.current().identity.stable_id == "b1", "session stub 应生效")
local UIManager = require("ui/uimanager")
UIManager:show({ probe = true })
Assert.len(shown, 1, "uimanager show 应被测试桩捕获")
shown = {}

-- 章序号不一致 → 弹窗，不先 sync
Progress.clearConflicts()
pending_row = {
    fraction = 0.4,
    chapter_idx = 3,
    chapter_fraction = 0.1,
    sync_status = 1,
}
Progress.pull(snapshot())
Stubs.flush()

Assert.eq(pulled, 1, "应先拉远端进度")
Assert.len(shown, 1, "章序号不一致时应弹冲突框")
Assert.len(synced, 0, "冲突时不应先 sync 推本地")

-- 选「保留本地」：落回 pending 行那份进度，不能重新采样实时位置（doc_fraction=0 在第 3 章章首）
do
    local box = shown[1]
    upserted = {}
    box.cancel_callback()
    Stubs.flush()
    Assert.len(upserted, 1, "应把本地那份进度写回")
    Assert.eq(upserted[1].chapter_idx, 3)
    Assert.eq(upserted[1].fraction, 0.4)
    Assert.eq(upserted[1].chapter_fraction, 0.1, "章内比例取 pending 行，不是实时的 0")
    Assert.eq(synced[1], "b1", "选本地后应推上去收敛")
end

-- 点空白关闭（两个 callback 都不跑）不应算已决议：同一本书还要能再问
do
    Progress.clearConflicts()
    shown = {}
    synced = {}
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 1)
    Progress.pull(snapshot()) -- 未决议 → 允许再问
    Stubs.flush()
    Assert.len(shown, 2, "弹窗被忽略时不应把本次会话标记为已问过")
    shown[2].ok_callback()
    Stubs.flush()
    shown = {}
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.eq(#shown, 0, "已决议后同一会话不再问")
end

-- 同章已同步进度与远端章内差 <1% → 不弹窗，复用本次响应直接落库。
Progress.clearConflicts()
shown = {}
synced = {}
remote_upserted = {}
pulled = 0
pending_row = {
    fraction = 0.41,
    chapter_idx = 3,
    chapter_fraction = 0.105,
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb({ fraction = 0.41, chapter_idx = 3, chapter_fraction = 0.11 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()

Assert.eq(pulled, 1)
Assert.eq(#shown, 0, "差异 <1% 时不弹窗")
Assert.eq(#synced, 0, "已有远端响应时不应再启动完整同步")
Assert.eq(#remote_upserted, 1, "应直接保存本次远端响应")

-- 本地脏进度已与云端基本一致 → 只推不拉，避免第二次 getProgress。
synced = {}
remote_upserted = {}
pending_row.sync_status = 0
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(synced[1], "b1")
Assert.is_true(synced.dirty_only, "脏本地只需上传")
Assert.eq(#remote_upserted, 0, "不能用远端覆盖脏本地")

-- 阅读器尚在章首但 pending 已与云端一致 → 不弹假冲突
Progress.clearConflicts()
shown = {}
synced = {}
remote_upserted = {}
pulled = 0
pending_row = {
    fraction = 0.41,
    chapter_idx = 3,
    chapter_fraction = 0.2,
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb({ fraction = 0.41, chapter_idx = 3, chapter_fraction = 0.2 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()

Assert.eq(pulled, 1)
Assert.eq(#shown, 0, "pending 与云端一致时不应假冲突")
Assert.eq(#synced, 0)
Assert.eq(#remote_upserted, 1)

-- 本地没有 pending 行：这是首次打开，不是“本地首页”和云端冲突；直接恢复云端位置。
Progress.clearConflicts()
shown = {}
remote_adopted = {}
pending_row = nil
current_identity.chapter_idx = nil
source.type = "book"
local jumped
current_ui = {
    document = {
        getXPointerFromProportion = function(_, pct)
            return "remote:" .. tostring(pct)
        end,
    },
    rolling = {
        onGotoXPointer = function(_, xpointer) jumped = xpointer end,
    },
}
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.62 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()

Assert.eq(#shown, 0, "首次打开没有本地进度，不应弹假冲突")
Assert.eq(#remote_adopted, 1, "首次打开应采纳云端进度")
Assert.eq(jumped, "remote:0.62", "首次打开应立即跳到云端位置")
Assert.not_nil(remote_adopted[1].updated_at, "采纳的云端进度必须进入最近阅读")

for _, name in ipairs({
    "ui/uimanager", "ui/widget/infomessage", "ui/widget/confirmbox", "ui/event",
    "ui.reader.session.toc", "ui.reader.session", "logger",
    "db.progress", "book.progress",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
