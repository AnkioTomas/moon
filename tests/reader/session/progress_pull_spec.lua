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
local live_xpointer -- 测试桩会话的 rolling.xpointer（页级源无进度行时的本地位置）
local precise_document
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
                ui = { document = precise_document or { getPageCount = function() return 10 end }, handleEvent = function() end,
                    rolling = live_xpointer and { xpointer = live_xpointer } },
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

-- 精确正文坐标按实际目标页比较：长章中 <1% 也可能差好几页。
do
    local remote
    precise_document = {
        getPageCount = function() return 1000 end,
        isXPointerInDocument = function() return true end,
        getPageFromXPointer = function(_, xp) return tonumber(xp:match("(%d+)$")) end,
    }
    source.getProgressAsync = function(_, _id, cb)
        cb(remote)
        return { cancel = function() end }
    end
    Progress.clearConflicts()
    shown, remote_upserted = {}, {}
    pending_row = {
        fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.5,
        locator = "page500", sync_status = 0,
    }
    remote = { fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.505, locator = "page505" }
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 1, "正文定位相差五页不能被 1% 容差吞掉")
    Assert.not_nil(shown[1].ok_callback)

    Progress.clearConflicts()
    shown, remote_upserted = {}, {}
    pending_row.sync_status = 1
    remote = { fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.8, locator = "same500" }
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 0, "字号或 HTML 改写造成比例不同，同页不能假冲突")
    Assert.len(remote_upserted, 1)

    Progress.clearConflicts()
    shown, goto_calls = {}, {}
    remote = { fraction = 0.6, chapter_idx = 4, locator = "/html/body/p/text().123" }
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.eq(goto_calls[1].idx, 4)
    Assert.eq(goto_calls[1].opts.xpointer, remote.locator, "跨章必须把精确正文坐标带到新文档")
    precise_document = nil
end

-- 微信式：远端有 locator、章内比是字符口径（或已清空）；不能拿页比例 1% 假冲突后静默 adopt。
do
    precise_document = {
        getPageCount = function() return 100 end,
        isXPointerInDocument = function() return false end, -- 比不了页，退回 locator 字符串
    }
    local remote
    source.getProgressAsync = function(_, _id, cb)
        cb(remote)
        return { cancel = function() end }
    end
    Progress.clearConflicts()
    shown, goto_calls, remote_upserted, adopted = {}, {}, {}, {}
    pending_row = {
        fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.5,
        locator = "xp-local", sync_status = 1,
        synced = { fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.5, locator = "xp-local" },
    }
    -- 远端字符比 0.2 vs 本地页比 0.5，但同一定位 → 必须视为一致，不能 adopt 跳走
    remote = { fraction = 0.4, chapter_idx = 3, chapter_fraction = 0.2, locator = "xp-local" }
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 0, "字符比与页比不同不能假冲突")
    Assert.len(adopted, 0, "已同步同定位不能静默跳走")
    Assert.len(remote_upserted, 1)

    -- 微信 localize 后 chapter_fraction 为 nil，仍有 locator：应落库，不能当「只记到章」跳过
    Progress.clearConflicts()
    shown, remote_upserted, adopted = {}, {}, {}
    remote = { fraction = 0.4, chapter_idx = 3, locator = "xp-local" }
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(shown, 0)
    Assert.len(adopted, 0)
    Assert.len(remote_upserted, 1, "有 locator 时 nil 章内比仍落库")

    -- 定位字符串不同且比不了页 → 算冲突（sync 已同步则静默 adopt）
    Progress.clearConflicts()
    shown, remote_upserted, adopted = {}, {}, {}
    remote = { fraction = 0.4, chapter_idx = 3, locator = "xp-cloud" }
    Progress.pull(snapshot())
    Stubs.flush()
    Assert.len(adopted, 1, "定位变了要静默跟云端")
    Assert.eq(adopted[1].locator, "xp-cloud")
    precise_document = nil
end

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

-- ── 页级源（Kavita）：只按 spine 序号 + spine 内元素路径判，绝不按百分比 ──────
-- 远端的比例是「第几个 spine」，本地是全书渲染页比例，两者不可比。
local function kavitaPull(remote, row)
    -- stable_id 保持 b1：测试桩的 ProgressDB.get 只认这个 id。
    current_identity = { source_id = "kavita", stable_id = "b1", source = source }
    source.getProgressAsync = function(_, _, cb)
        cb(remote, nil, { page_level = true })
        return { cancel = function() end }
    end
    Progress.clearConflicts()
    shown, synced, adopted, remote_upserted, goto_calls = {}, {}, {}, {}, {}
    pending_row = row
    Progress.pull(snapshot())
    Stubs.flush()
end

local spine15_190 = "/body[1]/DocFragment[15]/body[1]/p[190]/text()[1].150"

-- 同 spine、远端带页内锚点更靠后（网页端在同一条里往后读了几页）→ 静默采纳并跳转。
kavitaPull({ fraction = 0.64, total_pages = 22, locator = "/body/DocFragment[15]/body/p[312]" },
    { fraction = 0.61, page = 209, total_pages = 307, locator = spine15_190, sync_status = 1,
      synced = { fraction = 0.61, locator = spine15_190 } })
Assert.eq(#shown, 1, "只有「已跳转到」提示，没有冲突框")
Assert.is_nil(shown[1].ok_callback, "采纳是静默的，不该是冲突选择框")
Assert.len(adopted, 1, "云端动过就跟随远端的页内位置")
Assert.eq(adopted[1].locator, "/body/DocFragment[15]/body/p[312]", "位置用远端")
Assert.eq(adopted[1].fraction, 0.61, "同 spine 采纳保留本地的内容页比例（不用 spine 比例冲掉）")
Assert.eq(adopted[1].page, 209, "同 spine 采纳保留本地页码")
Assert.eq(adopted[1].total_pages, 307)

-- 同 spine、远端只有 spine 粒度且比例差 31% → 不弹窗、不采纳、不拿粗坐标盖本地（kavita 不看百分比）
kavitaPull({ fraction = 0.30, total_pages = 22, locator = "/body/DocFragment[15]/body" },
    { fraction = 0.61, locator = spine15_190, sync_status = 1,
      synced = { fraction = 0.61, locator = spine15_190 } })
Assert.eq(#shown, 0, "页级源不看百分比：同 spine 就不算冲突")
Assert.eq(#adopted, 0, "远端只有 spine 粒度就不动本地页内位置")
Assert.eq(#remote_upserted, 0, "不能拿 spine 粒度的远端盖掉本地页内坐标")

-- 同一位置的不同写法（归一化 vs 原始）不得当成冲突。
kavitaPull({ fraction = 0.63, total_pages = 22, locator = "/body/DocFragment[15]/body/p[190]" },
    { fraction = 0.61, locator = spine15_190, sync_status = 1,
      synced = { fraction = 0.61, locator = spine15_190 } })
Assert.eq(#shown, 0, "同 spine 同段号只是写法不同，不算冲突")
Assert.eq(#adopted, 0, "同一位置不需要跳转")

-- 跨 spine：本地自上次同步没动过 → 直接跟云端。
kavitaPull({ fraction = 0.52, total_pages = 24, locator = "/body/DocFragment[13]/body/p[3]" },
    { fraction = 0.25, locator = "/body/DocFragment[7]/body/p[1]", sync_status = 1,
      synced = { fraction = 0.25, locator = "/body/DocFragment[7]/body/p[1]" } })
Assert.eq(#shown, 1, "只有「已跳转到」提示，不弹冲突框")
Assert.is_nil(shown[1].ok_callback, "不是冲突选择框")
Assert.len(adopted, 1, "本地干净时直接跟到云端所在 spine")
Assert.eq(adopted[1].locator, "/body/DocFragment[13]/body/p[3]")
Assert.eq(adopted[1].fraction, 0.52, "跨 spine 整套用远端（本地那几个数描述的是别处）")

-- 跨 spine：两边都动过 → 弹窗（不把正在读别的章的人拽走）。
kavitaPull({ fraction = 0.52, total_pages = 24, locator = "/body/DocFragment[13]/body/p[3]" },
    { fraction = 0.25, locator = "/body/DocFragment[7]/body/p[1]", sync_status = 0 })
Assert.len(shown, 1, "跨 spine 且本地也有未推改动要问")
Assert.not_nil(shown[1].ok_callback, "弹的是本地/云端选择框")
Assert.eq(#adopted, 0, "未决议前不采纳")

-- 本地读得更靠后（云端在更早的 spine / 同 spine 内更靠前）→ 不往回拽、不弹窗。
kavitaPull({ fraction = 0.30, total_pages = 22, locator = "/body/DocFragment[13]/body/p[5]" },
    { fraction = 0.55, locator = "/body/DocFragment[15]/body/p[200]", sync_status = 1,
      synced = { fraction = 0.55, locator = "/body/DocFragment[15]/body/p[200]" } })
Assert.eq(#shown, 0, "本地更靠后不是冲突")
Assert.eq(#adopted, 0, "不能把读者往回拽")
Assert.eq(#synced, 0, "本地没有新改动，不必回推")

-- 同 spine 但本地更靠前（云端在同一条内更靠后）→ 照旧跟随。
kavitaPull({ fraction = 0.30, total_pages = 22, locator = "/body/DocFragment[15]/body/p[260]" },
    { fraction = 0.55, locator = "/body/DocFragment[15]/body/p[200]", sync_status = 1,
      synced = { fraction = 0.55, locator = "/body/DocFragment[15]/body/p[200]" } })
Assert.len(adopted, 1, "同 spine 内云端更靠后要跟")
Assert.eq(adopted[1].locator, "/body/DocFragment[15]/body/p[260]")

-- 本地有 spine、远端没有（远端没给 locator）：spineCmp 判不出，退回「一页」容差比比例。
kavitaPull({ fraction = 0.62, total_pages = 22 },
    { fraction = 0.61, locator = spine15_190, sync_status = 1,
      synced = { fraction = 0.61, locator = spine15_190 } })
Assert.eq(#shown, 0, "一页容差内不算冲突")
Assert.eq(#adopted, 0, "容差内不动本地")
kavitaPull({ fraction = 0.90, total_pages = 22 },
    { fraction = 0.61, page = 209, locator = spine15_190, sync_status = 1,
      synced = { fraction = 0.61, locator = spine15_190 } })
Assert.len(adopted, 1, "超出容差且本地没动过就跟云端")
Assert.eq(adopted[1].fraction, 0.90, "取不到同 spine 时整套用远端")
Assert.is_nil(adopted[1].page, "不保留本地页码")

-- 页级源、库里还没有进度行、本地 spine 比远端靠后：不能对 nil 行取字段，也不弹冲突框。
live_xpointer = "/body/DocFragment[15]/body/p[3]"
kavitaPull({ fraction = 0.30, total_pages = 22, locator = "/body/DocFragment[13]/body/p[5]" }, nil)
live_xpointer = nil
Assert.eq(#shown, 0, "无进度行时本地更靠后不弹窗")
Assert.eq(#adopted, 0, "不把读者往回拽")

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
