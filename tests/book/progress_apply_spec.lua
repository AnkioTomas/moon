--[[--
book.progress 位置恢复：XPointer > 页码 > 比例的降级顺序。

比例会随字号排版漂移，只能当兜底；精确坐标不可用时才允许退回它。

@module tests.book.progress_apply_spec
--]]

local Assert = require("support.assert")

local pending_row
local identity = { source_id = "moon", stable_id = "b1", chapter_idx = 3 }

package.preload["ui/uimanager"] = function()
    return { show = function() end, nextTick = function(fn) fn() end }
end
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
    return { list = function() return {} end, chapterFraction = function() return 0 end }
end
package.preload["ui.reader.session"] = function()
    return {
        current = function() return nil end,
        chapterTitle = function() return "" end,
        gotoChapter = function() return false end,
    }
end
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end
package.preload["db.progress"] = function()
    return { get = function() return pending_row end }
end

for _, name in ipairs({
    "ui/uimanager", "ui.reader.session", "ui.reader.session.toc",
    "db.progress", "book.progress",
}) do
    package.loaded[name] = nil
end

local Progress = require("book.progress")

--- 造一个 rolling（重排版）文档：xpointer 有效性由 valid 集合决定。
---@param valid table<string, boolean>
local function rollingUI(valid)
    local log = { goto_xpointer = {}, from_proportion = 0, saved = {}, flushed = 0 }
    return log, {
        document = {
            isXPointerInDocument = function(_, xp) return valid[xp] == true end,
            getXPointerFromProportion = function(_, pct)
                log.from_proportion = log.from_proportion + 1
                return "xp:from_pct:" .. tostring(pct)
            end,
        },
        rolling = {
            xpointer = "xp:current",
            onGotoXPointer = function(_, xp) log.goto_xpointer[#log.goto_xpointer + 1] = xp end,
        },
        doc_settings = {
            saveSetting = function(_, k, v) log.saved[k] = v end,
            flush = function() log.flushed = log.flushed + 1 end,
        },
    }
end

--- 造一个 paging（固定版式）文档：只有页码，没有 xpointer。
---@param page_count integer
local function pagingUI(page_count)
    local log = { events = {}, saved = {}, flushed = 0 }
    return log, {
        document = { getPageCount = function() return page_count end },
        paging = {},
        view = { state = { page = 7 } },
        handleEvent = function(_, ev) log.events[#log.events + 1] = ev end,
        doc_settings = {
            saveSetting = function(_, k, v) log.saved[k] = v end,
            flush = function() log.flushed = log.flushed + 1 end,
        },
    }
end

-- ── locator 有效：直接用 XPointer，不碰比例折算 ──────────────
do
    local log, ui = rollingUI({ ["xp:saved"] = true })
    pending_row = { chapter_idx = 3, chapter_fraction = 0.5, locator = "xp:saved" }
    Progress.applyLocalPending({ identity = identity, ui = ui })

    Assert.len(log.goto_xpointer, 1)
    Assert.eq(log.goto_xpointer[1], "xp:saved")
    Assert.eq(log.from_proportion, 0, "有精确坐标就不该按比例折算")
    -- sidecar 同步落盘，供原生阅读器下次开书使用
    Assert.eq(log.saved.last_xpointer, "xp:current")
    Assert.eq(log.saved.percent_finished, 0.5)
    Assert.eq(log.flushed, 1)
end

-- ── locator 不属于本文档：回落比例，绝不乱跳 ─────────────────
do
    local log, ui = rollingUI({ ["xp:other"] = true })
    pending_row = { chapter_idx = 3, chapter_fraction = 0.25, locator = "xp:stale" }
    Progress.applyLocalPending({ identity = identity, ui = ui })

    Assert.eq(log.from_proportion, 1, "失效坐标应回落到比例")
    Assert.len(log.goto_xpointer, 1)
    Assert.eq(log.goto_xpointer[1], "xp:from_pct:0.25")
end

-- ── 固定版式：总页数一致时认页码 ────────────────────────────
do
    local log, ui = pagingUI(300)
    pending_row = { chapter_idx = 3, chapter_fraction = 0.9, page = 42, total_pages = 300 }
    Progress.applyLocalPending({ identity = identity, ui = ui })

    Assert.len(log.events, 1)
    Assert.eq(log.events[1].name, "GotoPage")
    Assert.eq(log.events[1].args[1], 42, "页数没变，页码就是精确坐标")
    Assert.eq(log.saved.last_page, 7)
end

-- ── 固定版式：总页数变了，页码失去意义，回落比例 ──────────────
do
    local log, ui = pagingUI(280)
    pending_row = { chapter_idx = 3, chapter_fraction = 0.5, page = 42, total_pages = 300 }
    Progress.applyLocalPending({ identity = identity, ui = ui })

    Assert.len(log.events, 1)
    Assert.eq(log.events[1].args[1], 140, "0.5 × 280 页")
end

-- ── 章序号不匹配：不恢复，locator 是章内坐标 ─────────────────
do
    local log, ui = rollingUI({ ["xp:saved"] = true })
    pending_row = { chapter_idx = 9, chapter_fraction = 0.5, locator = "xp:saved" }
    Progress.applyLocalPending({ identity = identity, ui = ui })

    Assert.len(log.goto_xpointer, 0)
    Assert.eq(log.from_proportion, 0)
    Assert.eq(log.flushed, 0)
end

-- ── 什么坐标都没有：不动文档 ─────────────────────────────────
do
    local log, ui = rollingUI({})
    pending_row = { chapter_idx = 3 }
    Progress.applyLocalPending({ identity = identity, ui = ui })

    Assert.len(log.goto_xpointer, 0)
    Assert.eq(log.flushed, 0)
end

for _, name in ipairs({
    "ui/uimanager", "ui/widget/infomessage", "ui/widget/confirmbox", "ui/event",
    "ui.reader.session.toc", "ui.reader.session", "logger",
    "db.progress", "book.progress",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
