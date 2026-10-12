--[[--
reader.session.progress pull：开书后先拉远端再对比，冲突时不应先推脏本地。

@module tests.reader.session.progress_pull_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local shown = {}
local synced = {}
local upserted = {}
local remote_upserted = {}
local adopted = {}
local pulled = 0
local pending_row
local goto_calls = {}
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
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) require("ui/uimanager"):show(o) end
package.preload["ui/event"] = function()
    return { new = function(_, name, ...) return { name = name, args = { ... } } end }
end
package.preload["reader.session.toc"] = function()
    return {
        list = function() return { {}, {}, {}, {}, {} } end,
        chapterFraction = function() return 0 end,
    }
end
package.preload["reader.session"] = function()
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
                ui = { document = { getPageCount = function() return 10 end }, handleEvent = function() end },
                chapter = { toc = { {}, {}, {}, {}, {} } },
                doc_fraction = 0,
            }
        end,
        chapterTitle = function() return "" end,
        gotoChapter = function(idx, opts)
            goto_calls[#goto_calls + 1] = { idx = idx, opts = opts }
            return not goto_calls.fail
        end,
    }
end
package.loaded["reader.session"] = nil
package.loaded["reader.session.toc"] = nil
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end
package.preload["book.progress_db"] = function()
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
        adoptRemote = function(_, _, pos) adopted[#adopted + 1] = pos; return true end,
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
        ui = { document = { getPageCount = function() return 10 end }, handleEvent = function() end },
        chapter = { toc = { {}, {}, {}, {}, {} } },
        doc_fraction = 0,
    }
end

package.loaded["reader.session.progress"] = nil
local Progress = require("reader.session.progress")
local Session = require("reader.session")

Assert.is_true(Session.current().identity.stable_id == "b1", "session stub 应生效")
local UIManager = require("ui/uimanager")
UIManager:show({ probe = true })
Assert.len(shown, 1, "uimanager show 应被测试桩捕获")
shown = {}

-- 本地有未推改动、云端也不是上次同步的位置，章序号不一致 → 弹窗，不先 sync
Progress.clearConflicts()
pending_row = {
    fraction = 0.4,
    chapter_idx = 3,
    chapter_fraction = 0.1,
    sync_status = 0,
}
Progress.pull(snapshot())
Stubs.flush()

Assert.eq(pulled, 1, "应先拉远端进度")
Assert.len(shown, 1, "章序号不一致时应弹冲突框")
Assert.len(synced, 0, "冲突时不应先 sync 推本地")

-- 选「保留本地」：落回 pending 行那份进度，不能重新采样实时位置（doc_fraction=0 在第 3 章章首）
do
    local box = shown[1]
    Assert.is_true(box.dismissable == false, "点空白不能等同选本地（主题 Confirm 点外走 cancel_callback）")
    upserted = {}
    box.cancel_callback()
    Stubs.flush()
    Assert.len(upserted, 1, "应把本地那份进度写回")
    Assert.eq(upserted[1].chapter_idx, 3)
    Assert.eq(upserted[1].fraction, 0.4)
    Assert.eq(upserted[1].chapter_fraction, 0.1, "章内比例取 pending 行，不是实时的 0")
    Assert.eq(synced[1], "b1", "选本地后应推上去收敛")
end

-- 弹窗还没答时再 pull（换章 / 唤醒）不能叠第二个窗
do
    Progress.clearConflicts()
    shown = {}
    synced = {}
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 1)
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 1, "未答的冲突框不能叠窗")
    shown[1].ok_callback()
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

-- 云端只记到章（不回章内位置）且同章 → 不弹窗，也不拿章首覆盖本地章内位置
Progress.clearConflicts()
shown = {}
synced = {}
remote_upserted = {}
pending_row = {
    fraction = 0.41,
    chapter_idx = 3,
    chapter_fraction = 0.09,
    sync_status = 0,
}
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.4, chapter_idx = 3 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 0, "同章且云端没有章内位置 → 以本地为准")
Assert.eq(#remote_upserted, 0, "不能把本地 9% 冲成章首")
-- 换了章仍是冲突
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.8, chapter_idx = 5 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 1, "章不同照常询问")

-- 远端只有全书比例和章内比例时，也必须先推导章节号，不能把 nil 传给 gotoChapter。
Progress.clearConflicts()
shown = {}
goto_calls = {}
pending_row = {
    fraction = 0.4,
    chapter_idx = 3,
    chapter_fraction = 0.1,
    sync_status = 0,
}
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.6, chapter_fraction = 0.25 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.len(shown, 1)
shown[1].ok_callback()
Stubs.flush()
Assert.len(goto_calls, 1, "缺失 chapter_idx 时仍应按全书比例切章")
Assert.eq(goto_calls[1].idx, 4)
Assert.eq(goto_calls[1].opts.within, 0.25)

-- 选云端但切章失败：库已采纳云端，必须告诉用户没跳过去，不能静默停在原处。
Progress.clearConflicts()
shown = {}
goto_calls = { fail = true }
Progress.pull(snapshot())
Stubs.flush()
Assert.len(shown, 1)
shown[1].ok_callback()
Stubs.flush()
Assert.len(goto_calls, 1)
Assert.len(shown, 2, "切章失败应弹提示")
Assert.matches(shown[2].text, "失败")

-- 按「上次同步时的云端位置」判断谁动过：只有两边都动过才弹窗。
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.8, chapter_idx = 5, chapter_fraction = 0.2 })
    return { cancel = function() end }
end
local base = { fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.1 }
local function pullWith(row)
    Progress.clearConflicts()
    shown, synced, adopted, goto_calls = {}, {}, {}, {}
    pending_row = row
    Progress.pull(snapshot())
    Stubs.flush()
end

-- 云端仍是本机上次推上去的位置，本地新读的还没推：静默推送，不弹窗、不跳转。
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.1 })
    return { cancel = function() end }
end
pullWith({ fraction = 0.6, chapter_idx = 4, chapter_fraction = 0.3, sync_status = 0, synced = base })
Assert.eq(#shown, 0, "云端是自己的旧进度不算冲突")
Assert.eq(synced[1], "b1", "应把本地新进度推上去")
Assert.is_true(synced.dirty_only)
Assert.len(adopted, 0, "不能用旧云端覆盖本地")

-- 本地自上次同步没动过，云端被别的设备读到别处：静默跟云端，提示跳到哪里。
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.8, chapter_idx = 5, chapter_fraction = 0.2 })
    return { cancel = function() end }
end
pullWith({ fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.1, sync_status = 1, synced = base })
Assert.len(adopted, 1, "本地没改动时直接采用云端")
Assert.eq(adopted[1].chapter_idx, 5)
Assert.len(goto_calls, 1, "应跳到云端所在章")
Assert.eq(goto_calls[1].idx, 5)
Assert.len(synced, 0)
Assert.len(shown, 1, "只有跳转提示，没有冲突框")
Assert.matches(shown[1].text, "已跳转")

-- 旧库的已同步行没有基准：本地没改动，同样跟云端。
pullWith({ fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.1, sync_status = 1 })
Assert.len(adopted, 1)

-- 两边都动过：本地有未推改动，云端也不是上次同步的位置 → 弹窗。
pullWith({ fraction = 0.6, chapter_idx = 4, chapter_fraction = 0.3, sync_status = 0, synced = base })
Assert.len(shown, 1)
Assert.matches(shown[1].text, "要从哪里继续读")
Assert.len(adopted, 0)
Assert.len(synced, 0)

-- 拉失败只记日志，不弹窗：离线开缓存书必须能继续读
Progress.clearConflicts()
shown = {}
source.getProgressAsync = function(_, _, cb)
    cb(nil, "common/turbo/iostream.lua:476: attempt to index local 'self' (a string value)")
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 0, "进度拉取失败不应打断阅读")

-- 手动拉取（快捷面板）：本会话问过的冲突再问一次；无记录 / 失败 / 一致 / 离线都提示。
local net = true
package.loaded["ui/network/manager"] = { isConnected = function() return net end }
Progress.clearConflicts()
shown, goto_calls = {}, {}
pending_row = { fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.1, sync_status = 0 }
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb({ fraction = 0.8, chapter_idx = 8, chapter_fraction = 0.2 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Progress.pull(snapshot())
Stubs.flush()
Assert.len(shown, 1, "自动拉取每会话只问一次")
Progress.pull(snapshot(), { manual = true })
Stubs.flush()
Assert.len(shown, 2, "手动拉取重新询问")
Assert.matches(shown[2].text, "云端")

local function lastText()
    Stubs.flush()
    return shown[#shown].text
end
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.1 })
    return { cancel = function() end }
end
Progress.pull(snapshot(), { manual = true })
Assert.eq(lastText(), "本地与云端进度一致")
source.getProgressAsync = function(_, _, cb)
    cb(nil, nil, { empty = true })
    return { cancel = function() end }
end
Progress.pull(snapshot(), { manual = true })
Assert.eq(lastText(), "云端没有这本书的进度")
source.getProgressAsync = function(_, _, cb)
    cb(nil, "boom")
    return { cancel = function() end }
end
Progress.pull(snapshot(), { manual = true })
Assert.eq(lastText(), "拉取进度失败：boom")
net = false
pulled = 0
Progress.pull(snapshot(), { manual = true })
Assert.matches(lastText(), "网络不可用")
Assert.eq(pulled, 0)

-- 手动推送：先落本地（标脏），在线时推这一本；离线只落本地；失败提示原因。
upserted, synced = {}, {}
Progress.push(snapshot())
Assert.eq(lastText(), "已保存到本地，联网后自动同步")
Assert.len(upserted, 1)
Assert.len(synced, 0)
net = true
Progress.push(snapshot())
Assert.eq(lastText(), "进度已推送")
Assert.eq(synced[1], "b1")
Assert.is_nil(synced.dirty_only, "手动推送失败要报错，不走只推脏行的静默模式")
source.syncProgressAsync = function(_, _, cb)
    cb(nil, "denied")
    return { cancel = function() end }
end
Progress.push(snapshot())
Assert.eq(lastText(), "推送进度失败：denied")
package.loaded["ui/network/manager"] = nil

for _, name in ipairs({
    "ui/uimanager", "ui/widget/infomessage", "ui/widget/confirmbox", "ui/event",
    "reader.session.toc", "reader.session", "logger",
    "book.progress_db", "book.progress", "reader.session.progress",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
