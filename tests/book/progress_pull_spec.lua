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
                ui = {},
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
package.loaded["ui.reader.session"] = nil
package.loaded["ui.reader.session.toc"] = nil
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
package.preload["db.progress"] = function()
    return {
        get = function()
            return pending_row
        end,
        upsert = function(_, _, pos) upserted[#upserted + 1] = pos; return true end,
        upsertRemote = function(_, _, pos)
            remote_upserted[#remote_upserted + 1] = pos
            return true
        end,
        adoptRemote = function(_, _, pos)
            adopted[#adopted + 1] = pos
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
        synced.force = opts.force
        if cb then cb({ pulled = 0, pushed = 0 }) end
        return { cancel = function() end }
    end,
}
current_identity.source = source

local function snapshot()
    return {
        identity = current_identity,
        ui = {},
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
    Assert.is_true(synced.force, "选本地要 force 推，跳过「云端更靠后就不推」的比对")
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

-- 远端只有全书比例和章内比例时，也必须先推导章节号，不能把 nil 传给 gotoChapter。
Progress.clearConflicts()
shown = {}
goto_calls = {}
pending_row = {
    fraction = 0.4,
    chapter_idx = 3,
    chapter_fraction = 0.1,
    sync_status = 1,
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

-- book 源（如 Kavita 多卷）带 chapter_idx 时同样按章：冲突标签与切章都要走章节目录。
Progress.clearConflicts()
shown = {}
goto_calls = {}
source.type = "book"
pending_row = {
    fraction = 0.4,
    chapter_idx = 3,
    chapter_fraction = 0.1,
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.6, chapter_idx = 4, chapter_fraction = 0.2 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.len(shown, 1, "book 源多卷也应弹进度冲突")
Assert.matches(shown[1].text, "第 3 章", "冲突标签应按章显示")
shown[1].ok_callback()
Stubs.flush()
Assert.len(goto_calls, 1, "book 源多卷也应能切到云端章")
Assert.eq(goto_calls[1].idx, 4)
Assert.eq(goto_calls[1].opts.within, 0.2)

-- 整书 + 页级源（Kavita）：远端 locator 与本地同 spine → 不弹冲突，也不用页级粗值覆盖本地。
Progress.clearConflicts()
shown = {}
synced = {}
remote_upserted = {}
pulled = 0
current_identity = { source_id = "kavita", stable_id = "k42", source = source }
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb({
        fraction = 0.5,
        page = 13,
        total_pages = 24,
        locator = "/body/DocFragment[13]/body",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
pending_row = {
    fraction = 0.52,
    locator = "/body/DocFragment[13]/body/p[3]",
    sync_status = 1,
}
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(pulled, 1)
Assert.eq(#shown, 0, "同一 spine 的页级远端不应弹冲突")
Assert.eq(#remote_upserted, 0, "同 spine 时保留本地精确进度，不用页级粗值覆盖")

-- 同 spine 但远端已读完：采纳远端，读完状态要传播
Progress.clearConflicts()
shown = {}
remote_upserted = {}
adopted = {}
pending_row = {
    fraction = 0.99,
    locator = "/body/DocFragment[24]/body/p[1]",
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 1,
        page = 24,
        total_pages = 24,
        locator = "/body/DocFragment[24]/body",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 0, "同 spine 已读完不弹冲突")
Assert.len(adopted, 1, "远端已读完要采纳以传播读完状态")

-- 同 spine 远端元素路径更靠后（网页端在本书内继续读）→ 拉取并采纳远端
Progress.clearConflicts()
shown = {}
remote_upserted = {}
adopted = {}
pending_row = {
    fraction = 0.30,
    locator = "/body[1]/DocFragment[13]/body[1]/p[3]/text()[1].0",
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 0.52,
        page = 13,
        total_pages = 24,
        locator = "/body/DocFragment[13]/body/p[9]",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 0, "同 spine 不按百分比判冲突")
Assert.len(adopted, 1, "同 spine 远端更靠后要拉取并采纳")

-- 同 spine 远端更靠前 → 保留本地精确进度
Progress.clearConflicts()
shown = {}
adopted = {}
pending_row = {
    fraction = 0.52,
    locator = "/body[1]/DocFragment[13]/body[1]/p[9]/text()[1].0",
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 0.30,
        page = 13,
        total_pages = 24,
        locator = "/body/DocFragment[13]/body/p[3]",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 0, "同 spine 远端更靠前不弹冲突")
Assert.eq(#adopted, 0, "同 spine 远端更靠前保留本地")

-- 不同 spine：跨章节分歧 → 弹窗让用户选，绝不能静默跳转（用户手动读别的章不能被拽走）
Progress.clearConflicts()
shown = {}
adopted = {}
pending_row = {
    fraction = 0.25,
    locator = "/body/DocFragment[7]/body/p[1]",
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 0.52,
        page = 13,
        total_pages = 24,
        locator = "/body/DocFragment[13]/body/p[3]",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.len(shown, 1, "跨 spine 远端更靠后也要弹窗，不静默跳转")
Assert.eq(#adopted, 0, "弹窗未决议前不采纳云端")

-- 不同 spine：本地更靠后同样是分歧 → 弹窗（方向交给用户判断）
Progress.clearConflicts()
shown = {}
adopted = {}
pending_row = {
    fraction = 0.52,
    locator = "/body/DocFragment[13]/body/p[3]",
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 0.25,
        page = 7,
        total_pages = 24,
        locator = "/body/DocFragment[7]/body",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.len(shown, 1, "本地更靠后跨 spine 也要弹窗")
Assert.eq(#adopted, 0, "弹窗未决议前不采纳云端")

-- 无精确坐标：页级源按「一页」容差，round-trip 舍入不误报冲突
Progress.clearConflicts()
shown = {}
remote_upserted = {}
pending_row = { fraction = 0.54, sync_status = 1 }
source.getProgressAsync = function(_, _, cb)
    cb({ fraction = 0.5, page = 12, total_pages = 24 }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(#shown, 0, "同页范围内的页级比例差不弹冲突")

-- 本地行可能等于云端（历史上被静默改写过），但阅读器（sidecar）实际停在别的 spine：
-- 必须以实时 locator 判定，才能发现「本机与云端不在同一章」并弹窗。
-- 真实事故：Kavita「罪与罚」(7540) 网页端读到第七节，本地开书停在第三节。
Progress.clearConflicts()
shown = {}
adopted = {}
remote_upserted = {}
pending_row = {
    fraction = 11 / 52,
    chapter_idx = 1,
    chapter_fraction = 11 / 52,
    page = 12,
    total_pages = 52,
    locator = "/body/DocFragment[12]/body",
    sync_status = 1,
}
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 11 / 52,
        chapter_idx = 1,
        chapter_fraction = 11 / 52,
        page = 12,
        total_pages = 52,
        locator = "/body/DocFragment[12]/body",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
Progress.pull({
    identity = current_identity,
    ui = {},
    doc_fraction = 0,
    -- 阅读器实时停在更早的 spine（第三节），pending 行已是远端（第七节）。
    locator = "/body[1]/DocFragment[8]/body[1]/p[3]/text()[1].10",
})
Stubs.flush()
Assert.len(shown, 1, "行=云端但阅读器实时位置在别的 spine 时，必须弹窗（需要实时 locator）")
Assert.eq(#adopted, 0, "弹窗未决议前不采纳云端")

-- 首次打开（本地无进度行）：云端有进度 → 直接采纳并跳转，不弹冲突询问。
Progress.clearConflicts()
shown = {}
goto_calls = {}
adopted = {}
pulled = 0
pending_row = nil
current_identity = { source_id = "wechat", stable_id = "newbook", chapter_idx = 1, source = source }
source.type = "chapter"
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb({ fraction = 0.8, chapter_idx = 8, chapter_fraction = 0.2 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(pulled, 1, "首次打开也要先拉云端进度")
Assert.len(adopted, 1, "首次打开应直接采纳云端进度")
Assert.eq(adopted[1].chapter_idx, 8)
Assert.len(goto_calls, 1, "首次打开应直接跳转到云端位置")
Assert.eq(goto_calls[1].idx, 8)
Assert.eq(goto_calls[1].opts.within, 0.2)
for _, widget in ipairs(shown) do
    Assert.is_nil(widget.ok_callback, "首次打开不应弹进度冲突框")
    Assert.is_nil(widget.cancel_callback, "首次打开不应弹进度冲突框")
end

-- 首次打开但云端无进度（meta.empty）：什么都不做，不采纳也不跳转。
Progress.clearConflicts()
shown = {}
goto_calls = {}
adopted = {}
pulled = 0
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb(nil, nil, { empty = true })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(pulled, 1)
Assert.eq(#adopted, 0, "云端无进度时不应采纳")
Assert.eq(#goto_calls, 0, "云端无进度时不应跳转")
Assert.eq(#shown, 0)

-- 首次打开但远端是零值进度（微信对没读过的书会回零值）：不能据此改写本地或跳转。
Progress.clearConflicts()
shown = {}
goto_calls = {}
adopted = {}
pulled = 0
source.getProgressAsync = function(_, _, cb)
    pulled = pulled + 1
    cb({ fraction = 0, chapter_idx = 1, chapter_fraction = 0 })
    return { cancel = function() end }
end
Progress.pull(snapshot())
Stubs.flush()
Assert.eq(pulled, 1)
Assert.eq(#adopted, 0, "零值远端不算有进度")
Assert.eq(#goto_calls, 0, "零值远端不应跳转")
Assert.eq(#shown, 0, "零值远端不应弹提示")

-- 手动拉取（pull manual）：有冲突弹「本地/云端」；即便本会话已问过也要能再弹
Progress.clearConflicts()
shown = {}
adopted = {}
current_identity = { source_id = "kavita", stable_id = "k99", source = source }
source.type = "book"
source.getProgressAsync = function(_, _, cb)
    cb({
        fraction = 0.5, page = 13, total_pages = 24,
        locator = "/body/DocFragment[13]/body",
    }, nil, { page_level = true })
    return { cancel = function() end }
end
pending_row = {
    fraction = 0.25,
    locator = "/body/DocFragment[7]/body/p[1]",
    sync_status = 1,
}
Progress.asked_conflicts["kavita\31k99"] = true -- 手动触发必须无视会话去重
Progress.pull({
    identity = current_identity, ui = {}, doc_fraction = 0,
    locator = "/body/DocFragment[7]/body/p[1]",
}, { manual = true })
Stubs.flush()
Assert.len(shown, 1, "手动拉取有冲突要弹窗")
Assert.not_nil(shown[1].cancel_callback, "弹的是本地/云端选择框")

-- 手动拉取：无冲突 → 提示「进度已是最新」（InfoMessage，不是冲突框）
shown = {}
pending_row = {
    fraction = 0.52,
    locator = "/body/DocFragment[13]/body/p[3]",
    sync_status = 1,
}
Progress.pull({
    identity = current_identity, ui = {}, doc_fraction = 0,
    locator = "/body/DocFragment[13]/body/p[3]",
}, { manual = true })
Stubs.flush()
Assert.len(shown, 1, "无冲突也要有反馈")
Assert.is_nil(shown[1].ok_callback, "无冲突不是冲突框")
Assert.is_true(tostring(shown[1].text):find("已是最新", 1, true) ~= nil, "提示进度已是最新")

-- 手动拉取：远端无进度 → 提示
shown = {}
source.getProgressAsync = function(_, _, cb)
    cb(nil, nil, { empty = true })
    return { cancel = function() end }
end
Progress.pull({
    identity = current_identity, ui = {}, doc_fraction = 0,
    locator = "/body/DocFragment[7]/body/p[1]",
}, { manual = true })
Stubs.flush()
Assert.len(shown, 1, "云端无进度要有提示")
Assert.is_nil(shown[1].ok_callback)

-- 手动推送（push）：落盘当前进度后 force 推；成功后提示
shown = {}
local saved_pos, sync_opts
package.loaded["book.progress"] = nil
Progress = require("book.progress")
local push_source = {
    id = "kavita",
    syncProgressAsync = function(_, opts, cb)
        sync_opts = opts
        if cb then cb({ pushed = 1 }) end
        return { cancel = function() end }
    end,
}
current_identity = { source_id = "kavita", stable_id = "k100", source = push_source }
Progress.asked_conflicts["kavita\31k100"] = nil
Progress.push({
    identity = current_identity, ui = {}, doc_fraction = 0.3,
    locator = "/body/DocFragment[7]/body/p[1]",
})
Stubs.flush()
Assert.not_nil(sync_opts, "push 要把进度推给源")
Assert.is_true(sync_opts.force, "手动推送 force 覆盖云端，不做比对")
Assert.eq(sync_opts.identity.stable_id, "k100")
Assert.len(shown, 1, "推送成功要有提示")
Assert.is_nil(shown[1].ok_callback)
Assert.is_true(tostring(shown[1].text):find("云端", 1, true) ~= nil, "提示已同步到云端")

for _, name in ipairs({
    "ui/uimanager", "ui/widget/infomessage", "ui/widget/confirmbox", "ui/event",
    "ui.reader.session.toc", "ui.reader.session", "logger",
    "db.progress", "book.progress", "ui/network/manager",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
