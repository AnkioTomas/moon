--[[--
连续章节手动刷新目录：绕过节流、更新会话 toc、失败提示。

@module tests.reader.session.refresh_toc_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["ffi/util"] = function()
    return {
        template = function(fmt, ...)
            local args = { ... }
            return (fmt:gsub("%%(%d+)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    }
end

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local dirty = 0
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() dirty = dirty + 1 end,
        show = function() end,
        close = function() end,
    }
end

local toc_ready = 0
package.preload["reader.session.progress"] = function()
    return { onTocReady = function() toc_ready = toc_ready + 1 end }
end

package.preload["reader.session.snapshot"] = function()
    return { refresh = function() end }
end

package.preload["source.chapter"] = function()
    return { prefetch = function() return { cancel = function() end } end }
end

package.loaded["reader.session.chapter"] = nil
local Chapter = require("reader.session.chapter")

Assert.is_false(Chapter.refreshToc(nil))
Assert.is_false(Chapter.refreshToc({ identity = {}, chapter = {} }))

do
    connected = false
    local identity = {
        chapter_idx = 1, source_id = "qidian", stable_id = "1",
        source = { refreshTocAsync = function() end },
    }
    local snap = { identity = identity, chapter = { identity = identity, toc = {} } }
    Assert.is_false(Chapter.refreshToc(snap))
    Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
    connected = true
end

do
    local identity = { chapter_idx = 1, source_id = "x", stable_id = "1", source = {} }
    local snap = { identity = identity, chapter = { identity = identity, toc = {} } }
    Assert.is_false(Chapter.refreshToc(snap))
    Assert.eq(Themed.last("toast").text, "当前书源不支持刷新目录")
end

do
    local cb
    local identity = {
        chapter_idx = 2, source_id = "qidian", stable_id = "9",
        source = {
            refreshTocAsync = function(_self, _id, done)
                cb = done
                return { cancel = function() end }
            end,
            prefetchChaptersAsync = function()
                return { cancel = function() end }
            end,
        },
    }
    local chapter = { identity = identity, toc = { { idx = 1 }, { idx = 2 } } }
    local snap = { ui = { dialog = {} }, identity = identity, chapter = chapter }
    dirty, toc_ready = 0, 0
    Assert.is_true(Chapter.refreshToc(snap))
    Assert.eq(Themed.last("progress_dialog").title, "刷新目录")
    Assert.is_true(chapter.refreshing_toc)
    cb({ { idx = 1 }, { idx = 2 }, { idx = 3 } })
    Assert.is_nil(chapter.refreshing_toc)
    Assert.eq(#chapter.toc, 3)
    Assert.eq(toc_ready, 1)
    Assert.eq(dirty, 1)
    Assert.eq(Themed.last("toast").text, "目录已更新（3 章）")
end

do
    local cb
    local identity = {
        chapter_idx = 1, source_id = "qidian", stable_id = "9",
        source = {
            refreshTocAsync = function(_self, _id, done)
                cb = done
                return { cancel = function() end }
            end,
        },
    }
    local chapter = { identity = identity, toc = { { idx = 1 } } }
    local snap = { ui = { dialog = {} }, identity = identity, chapter = chapter }
    Assert.is_true(Chapter.refreshToc(snap))
    cb(nil, "boom")
    Assert.eq(#chapter.toc, 1, "失败不动旧目录")
    Assert.eq(Themed.last("toast").text, "boom")
end

do
    local cb, cancelled = nil, false
    local identity = {
        chapter_idx = 1, source_id = "qidian", stable_id = "9",
        source = {
            refreshTocAsync = function(_self, _id, done)
                cb = done
                return { cancel = function() cancelled = true end }
            end,
        },
    }
    local chapter = { identity = identity, toc = { { idx = 1 } } }
    local snap = { ui = { dialog = {} }, identity = identity, chapter = chapter }
    local toasts_before = #Themed.all("toast")
    Assert.is_true(Chapter.refreshToc(snap))
    local dialog = Themed.last("progress_dialog")
    dialog.on_cancel()
    Assert.is_true(cancelled)
    Assert.is_nil(chapter.refreshing_toc)
    cb({ { idx = 1 }, { idx = 2 } })
    Assert.eq(#chapter.toc, 1, "取消后迟到回包不得改 toc")
    Assert.eq(#Themed.all("toast"), toasts_before, "取消后不得再 toast")
end

return true
