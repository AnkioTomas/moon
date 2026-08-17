--[[--
book.progress flushPending 离线用例（stub ProgressDB / UI）

@module tests.book.progress_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local pending = {
    {
        source_id = "moon",
        stable_id = "a.epub",
        fraction = 0.4,
        updated_at = 1,
    },
    {
        source_id = "moon",
        stable_id = "b.epub",
        fraction = 0.9,
        updated_at = 2,
    },
}
local deleted = {}

package.preload["utils.db.progress"] = function()
    return {
        all = function(source_id)
            local out = {}
            for _, r in ipairs(pending) do
                if r.source_id == source_id then
                    out[#out + 1] = r
                end
            end
            return out
        end,
        delete = function(source_id, stable_id)
            deleted[#deleted + 1] = source_id .. ":" .. stable_id
            return true
        end,
        upsert = function()
            return true
        end,
    }
end

package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            -- 测试环境同步执行 worker（无 write_fd），然后回调 on_done
            worker(nil)
            if opts and opts.on_done then
                opts.on_done(nil)
            end
        end,
        clear = function() end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/event"] = function()
    return {
        new = function(_, name, ...)
            return { name = name, args = { ... } }
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        runWhenOnline = function(_, fn)
            fn()
        end,
    }
end
-- identityFor 由用例控制（nil = 未识别）
local store_identity = nil
package.preload["book.store"] = function()
    return {
        identityFor = function()
            return store_identity
        end,
    }
end
-- 进度冲突弹窗：捕获 box 表供用例触发回调
local conflict_boxes = {}
package.preload["ui/widget/confirmbox"] = function()
    return {
        new = function(_, o)
            conflict_boxes[#conflict_boxes + 1] = o
            return o
        end,
    }
end
-- 整本书路径不走章会话，但 applyRemotePos 会 require
package.preload["chapters.init"] = function()
    return {
        isActive = function() return false end,
        chapterCount = function() return nil end,
        gotoChapter = function() end,
    }
end

package.loaded["book.progress"] = nil
package.loaded["utils.db.progress"] = nil
package.loaded["ui/widget/infomessage"] = nil
package.loaded["source.contract"] = nil

local Progress = require("book.progress")

local pushed = {}
local source = {
    id = "moon",
    putProgress = function(_, ref, pos)
        pushed[#pushed + 1] = { ref.stable_id, pos.fraction }
        return { cancel = function() end }
    end,
}

source.putProgressAsync = function(_, ref, pos, cb)
    pushed[#pushed + 1] = { ref.stable_id, pos.fraction }
    cb(true)
    return { cancel = function() end }
end

local n
Progress.flushPendingAsync(source, false, function(count)
    n = count
end)
Stubs.flush()
Assert.eq(n, 2)
Assert.eq(#pushed, 2)
Assert.eq(pushed[1][1], "a.epub")
Assert.eq(#deleted, 2)

local no_push
Progress.flushPendingAsync({
    id = "moon",
}, false, function(count)
    no_push = count
end)
Assert.eq(no_push, 0)

-- ---------------------------------------------------------------------------
-- pull：云端与本地不一致时的冲突弹窗
-- ---------------------------------------------------------------------------

-- 固定身份：moon:b1 整本书（无 chapter_idx）
store_identity = { ref = { source_id = "moon", stable_id = "b1" }, chapter_idx = nil }

--- 造假 ui：页码控制本地比例（page/100）
local function makeUI(page)
    local ui = {
        document = {
            file = "/books/b1.epub",
            getPageCount = function() return 100 end,
        },
        events = {},
    }
    function ui:getCurrentPage()
        return page
    end
    function ui:handleEvent(ev)
        self.events[#self.events + 1] = ev
    end
    return ui
end

--- 造只带 getProgressAsync 的假源（无 putProgressAsync：flush 直接 cb(0)）
local function makePullSource(pos)
    return {
        id = "moon",
        getProgressAsync = function(_, _ref, cb)
            cb(pos)
        end,
    }
end

-- 本地 0.5 vs 云端 0.5：一致不弹窗
do
    Progress.clearConflicts()
    local base = #conflict_boxes
    Progress.pull(makeUI(50), makePullSource({ fraction = 0.5 }), false)
    Stubs.flush()
    Assert.eq(#conflict_boxes, base)
end

-- 本地 0.1 vs 云端 0.8：弹窗一次；同书再问被记忆；clearConflicts 后重问
do
    Progress.clearConflicts()
    local base = #conflict_boxes
    local ui = makeUI(10)
    local src = makePullSource({ fraction = 0.8 })
    Progress.pull(ui, src, false)
    Stubs.flush()
    Assert.eq(#conflict_boxes, base + 1)
    -- 同书本次会话只问一次
    Progress.pull(ui, src, false)
    Stubs.flush()
    Assert.eq(#conflict_boxes, base + 1)
    -- 真关书清记忆后重新询问
    Progress.clearConflicts()
    Progress.pull(ui, src, false)
    Stubs.flush()
    Assert.eq(#conflict_boxes, base + 2)
    local box = conflict_boxes[#conflict_boxes]
    Assert.matches(box.text, "进度不一致")
    Assert.eq(box.ok_text, "云端 80.0%")
    Assert.eq(box.cancel_text, "本地 10.0%")
end

-- 选云端（ok_callback）：整本书按页码跳转 GotoPage
do
    Progress.clearConflicts()
    local ui = makeUI(10)
    Progress.pull(ui, makePullSource({ fraction = 0.8 }), false)
    Stubs.flush()
    conflict_boxes[#conflict_boxes].ok_callback()
    Assert.eq(#ui.events, 1)
    Assert.eq(ui.events[1].name, "GotoPage")
    Assert.eq(ui.events[1].args[1], 80) -- floor(0.8*100+0.5)
end

-- 选云端（ok_callback）：有 XPointer 引擎时走 onGotoXPointer
do
    Progress.clearConflicts()
    local ui = makeUI(10)
    local xptr
    ui.document.getXPointerFromProportion = function(_, pct)
        return "xp:" .. tostring(pct)
    end
    ui.rolling = {
        onGotoXPointer = function(_, x)
            xptr = x
        end,
    }
    Progress.pull(ui, makePullSource({ fraction = 0.8 }), false)
    Stubs.flush()
    conflict_boxes[#conflict_boxes].ok_callback()
    Assert.eq(xptr, "xp:0.8")
end

-- 选本地（cancel_callback）：本地进度推上行收敛
do
    Progress.clearConflicts()
    local ui = makeUI(10)
    local puts = {}
    local src = makePullSource({ fraction = 0.8 })
    src.putProgressAsync = function(_, ref, pos, cb)
        puts[#puts + 1] = { stable_id = ref.stable_id, fraction = pos.fraction }
        cb(true)
        return { cancel = function() end }
    end
    Progress.pull(ui, src, false)
    Stubs.flush()
    conflict_boxes[#conflict_boxes].cancel_callback()
    Stubs.flush()
    -- push 会把本地 0.1 推给云端（flush 也会顺带重推 pending 里的旧行，按 stable_id 找 b1）
    local found
    for _, p in ipairs(puts) do
        if p.stable_id == "b1" then
            found = p
        end
    end
    Assert.not_nil(found)
    Assert.eq(found.fraction, 0.1)
end

for _, k in ipairs({
    "utils.db.progress",
    "ui/widget/infomessage",
    "ui/event",
    "ui/network/manager",
    "ui/widget/confirmbox",
    "chapters.init",
    "book.store",
    "book.progress",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
