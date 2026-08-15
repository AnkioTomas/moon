--[[--
ui.reader.session 离线用例：身份自举 / 快照 / page_changed 分发 / 会话清理。

@module tests.ui.reader.session_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local calls = { tracker = {}, progress = {}, chapter = {}, reader = {} }

package.preload["book.store"] = function()
    return {
        identityFor = function(path)
            if path == "/x/book.epub" then
                return { ref = { source_id = "moon", stable_id = "b1" }, chapter_idx = nil }
            end
            return nil
        end,
    }
end

package.preload["stats.tracker"] = function()
    return {
        start = function(ui)
            calls.tracker[#calls.tracker + 1] = { "start", ui }
        end,
        stop = function()
            calls.tracker[#calls.tracker + 1] = { "stop" }
        end,
        onPage = function(ui, page)
            calls.tracker[#calls.tracker + 1] = { "onPage", page }
        end,
    }
end

package.preload["book.progress"] = function()
    return {
        pull = function(ui, source, show_msg)
            calls.progress[#calls.progress + 1] = { "pull", source }
        end,
        push = function(ui, source, show_msg)
            calls.progress[#calls.progress + 1] = { "push", source }
        end,
        fraction = function(ui)
            return 0.25
        end,
    }
end

local chapter_state = { active = false }
package.preload["chapters.init"] = function()
    return {
        isActive = function()
            return chapter_state.active
        end,
        ref = function()
            return { source_id = "moon", stable_id = "b2" }
        end,
        source = function()
            return { id = "moon" }
        end,
        book = function()
            return { title = "章书" }
        end,
        currentIdx = function()
            return 3
        end,
        chapterCount = function()
            return 10
        end,
        onReaderReady = function(ui)
            calls.chapter[#calls.chapter + 1] = { "ready", ui }
        end,
        onCloseDocument = function(path)
            calls.chapter[#calls.chapter + 1] = { "close", path }
        end,
        onEndOfBook = function()
            return false
        end,
        onStartOfBook = function()
            return false
        end,
    }
end

package.preload["chapters.patches"] = function()
    return {
        enable = function() end,
        wrapReaderUi = function() end,
    }
end

package.preload["ui.reader"] = function()
    return {
        attach = function(plugin)
            calls.reader[#calls.reader + 1] = { "attach" }
        end,
        refresh = function(plugin)
            calls.reader[#calls.reader + 1] = { "refresh" }
        end,
    }
end

local Session = require("ui.reader.session")

---@param path string
local function mkPlugin(path)
    local emitted = {}
    local plugin = {
        ui = {
            document = {
                file = path,
                getPageCount = function()
                    return 200
                end,
            },
            getCurrentPage = function()
                return 5
            end,
        },
        getSource = function()
            return { id = "moon" }
        end,
        emitToSource = function(_, ev, payload)
            emitted[#emitted + 1] = { ev = ev, payload = payload }
        end,
    }
    return plugin, emitted
end

-- 无身份文档：会话不活跃，行为零变化（统计/拉进度/reader_ready 照常）
do
    local plugin, emitted = mkPlugin("/other/plain.epub")
    Session.onReaderReady(plugin)
    Assert.is_false(Session.isActive(), "无身份不建会话")
    Assert.eq(calls.tracker[1][1], "start")
    Assert.eq(calls.progress[1][1], "pull")
    Assert.eq(calls.reader[#calls.reader][1], "attach")
    Assert.eq(emitted[#emitted].ev, "reader_ready")
end

-- 有身份文档：建会话并快照页码/页数/百分比
do
    local plugin, emitted = mkPlugin("/x/book.epub")
    Session.onReaderReady(plugin)
    Assert.is_true(Session.isActive())
    local cur = Session.current()
    Assert.eq(cur.ref.stable_id, "b1")
    Assert.eq(cur.page, 5)
    Assert.eq(cur.total_pages, 200)
    Assert.eq(cur.percent, 25)
    Assert.is_nil(cur.chapter_count, "整本书无章数")

    -- 翻页：更新快照 + 刷新 + 分发 page_changed
    Session.onPageUpdate(plugin, 6)
    Assert.eq(Session.current().page, 6)
    Assert.eq(calls.reader[#calls.reader][1], "refresh")
    local ev = emitted[#emitted]
    Assert.eq(ev.ev, "page_changed")
    Assert.eq(ev.payload.ref.stable_id, "b1")
    Assert.eq(ev.payload.page, 6)
    Assert.eq(ev.payload.total_pages, 200)
    Assert.eq(ev.payload.percent, 25)

    -- 滚动视图同路径
    Session.onPosUpdate(plugin, 7)
    Assert.eq(emitted[#emitted].payload.page, 7)

    -- 关文档：推进度/结清/通知源/清会话
    Session.onCloseDocument(plugin)
    Assert.is_false(Session.isActive(), "关书清会话")
    Assert.eq(calls.progress[#calls.progress][1], "push")
    Assert.eq(calls.tracker[#calls.tracker][1], "stop")
    Assert.eq(emitted[#emitted].ev, "document_close")
    Assert.eq(calls.chapter[#calls.chapter][1], "close")
    Assert.eq(calls.chapter[#calls.chapter][2], "/x/book.epub")

    -- 不活跃时翻页：统计照收，源不收事件
    local n = #emitted
    Session.onPageUpdate(plugin, 8)
    Assert.eq(#emitted, n, "不活跃不分发")
    Assert.eq(calls.tracker[#calls.tracker][1], "onPage")
end

-- 章会话：身份优先取章会话（文档路径无登记也活跃）
do
    chapter_state.active = true
    local plugin, emitted = mkPlugin("/other/3.html")
    Session.onReaderReady(plugin)
    Assert.is_true(Session.isActive(), "章会话活跃")
    local cur = Session.current()
    Assert.eq(cur.ref.stable_id, "b2")
    Assert.eq(cur.chapter_idx, 3)
    Assert.eq(cur.chapter_count, 10)
    Assert.eq(cur.book.title, "章书")
    Assert.eq(cur.source.id, "moon")
    Assert.eq(calls.chapter[#calls.chapter][1], "ready", "按章落点被调用")
    Session.onCloseDocument(plugin)
    chapter_state.active = false
end

-- 清理：fake 经 package.preload 安装，runner 只清 package.loaded，
-- 不卸会污染后续 spec（如 stats/tracker_spec 需要真 stats.tracker）
for _, name in ipairs({
    "book.store", "stats.tracker", "book.progress",
    "chapters.init", "chapters.patches", "ui.reader",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["ui.reader.session"] = nil
