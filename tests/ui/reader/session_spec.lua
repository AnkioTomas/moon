--[[--
ui.reader.session 离线用例：身份自举 / 快照 / page_changed 分发 / 会话清理。

@module tests.ui.reader.session_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local calls = { tracker = {}, progress = {}, chapter = {}, reader = {} }
local defer_tracker_stop = false
local tracker_stop_done
local resolved_source
local stored_toc = {}
local toc_reads = 0
local default_source = {
    id = "moon",
    type = "book",
    putProgressAsync = function() end,
    syncProgressAsync = function(_, opts, cb)
        calls.progress[#calls.progress + 1] = { "sync", opts.identity }
        if cb then cb({}) end
    end,
    syncNotesAsync = function(_, opts, cb)
        calls.notes = calls.notes or {}
        calls.notes[#calls.notes + 1] = { opts.identity, "sync" }
        if cb then cb({}) end
    end,
    syncStatsAsync = function(_, _, cb) if cb then cb({}) end end,
}
local chapter_default_source = {
    id = "moon",
    type = "chapter",
    putProgressAsync = default_source.putProgressAsync,
    syncProgressAsync = default_source.syncProgressAsync,
    syncNotesAsync = default_source.syncNotesAsync,
    syncStatsAsync = default_source.syncStatsAsync,
}

package.preload["book.store"] = function()
    return {
        ensureIdentity = function(path)
            if path == "/x/book.epub" then
                return {
                    source_id = "moon",
                    stable_id = "b1",
                    chapter_idx = nil,
                    book = { title = "整本书" },
                    source = resolved_source or default_source,
                }
            end
            if path == "/other/3.html" then
                return {
                    source_id = "moon",
                    stable_id = "b2",
                    chapter_idx = 3,
                    book = { title = "旧章书" },
                    source = resolved_source or chapter_default_source,
                }
            end
            if path == "/other/9.html" then
                return {
                    source_id = "moon",
                    stable_id = "b2",
                    chapter_idx = 9,
                    book = { title = "旧章书" },
                    source = resolved_source or chapter_default_source,
                }
            end
            if path == "/other/plain.epub" then
                return {
                    source_id = "local",
                    stable_id = "/other/plain.epub",
                    chapter_idx = nil,
                    book = { title = "plain" },
                    source = { id = "local", type = "book" },
                }
            end
            if path == "/cache/1.html" or path == "/cache/2.html" then
                return {
                    source_id = "moon",
                    stable_id = "chapters",
                    chapter_idx = path == "/cache/1.html" and 1 or 2,
                    book = { title = "章节书" },
                    source = resolved_source or chapter_default_source,
                }
            end
            return nil
        end,
        toc = function(identity)
            toc_reads = toc_reads + 1
            return stored_toc[identity.stable_id]
        end,
    }
end

package.preload["book.reader_prefs"] = function()
    return {
        apply = function() end,
        captureAndSave = function() end,
    }
end

package.preload["book.stats"] = function()
    return {
        start = function(ui, identity)
            calls.tracker[#calls.tracker + 1] = { "start", ui, identity }
        end,
        stop = function(done)
            calls.tracker[#calls.tracker + 1] = { "stop" }
            if defer_tracker_stop then
                tracker_stop_done = done
            elseif done then
                done()
            end
        end,
        onPage = function(ui, page)
            calls.tracker[#calls.tracker + 1] = { "onPage", page }
        end,
    }
end

package.preload["book.note"] = function()
    return {
        save = function(ui, identity, cb)
            calls.notes = calls.notes or {}
            calls.notes[#calls.notes + 1] = { identity, ui }
            if cb then cb(true) end
        end,
        applyLocal = function(ui, identity)
            calls.notes = calls.notes or {}
            calls.notes[#calls.notes + 1] = { identity, "apply_local" }
            return 0
        end,
        pull = function(ui, identity)
            calls.notes = calls.notes or {}
            calls.notes[#calls.notes + 1] = { identity, "pull" }
        end,
        push = function(ui, identity)
            calls.notes = calls.notes or {}
            calls.notes[#calls.notes + 1] = { identity, "push", ui }
        end,
    }
end

package.preload["book.progress"] = function()
    return {
        save = function(_, cb) if cb then cb(true) end end,
        pull = function(snapshot)
            calls.progress[#calls.progress + 1] = { "pull", snapshot and snapshot.identity }
        end,
        push = function(ui, identity)
            calls.progress[#calls.progress + 1] = { "push", identity }
        end,
        clearConflicts = function()
            calls.progress[#calls.progress + 1] = { "clearConflicts" }
        end,
        applyLocalPending = function(snapshot)
            calls.progress[#calls.progress + 1] = { "applyLocalPending", snapshot and snapshot.identity }
        end,
        position = function(snapshot)
            local identity = snapshot and snapshot.identity
            calls.progress_position_identity = identity
            local fraction = identity and identity.chapter_idx and 0.75 or 0.25
            return {
                fraction = fraction,
                chapter_idx = identity and identity.chapter_idx,
                chapter_fraction = identity and identity.chapter_idx and 0.5 or nil,
            }
        end,
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
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end

package.preload["utils.db.stats"] = function()
    return {
        summaryByBook = function(source_id, stable_id)
            if source_id == "moon" and (stable_id == "b1" or stable_id == "chapters") then
                return { total_seconds = 6000, pages = 100, last_read = 0 }
            end
            return { total_seconds = 0, pages = 0, last_read = 0 }
        end,
    }
end

local Session = require("ui.reader.session")

local function asyncChapter(path, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if not cancelled then cb(path) end
    end)
    return { cancel = function() cancelled = true end }
end

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
        emitToSource = function(_, ev, payload, source)
            emitted[#emitted + 1] = { ev = ev, payload = payload, source = source }
        end,
    }
    return plugin, emitted
end

-- 首次路径由源解析；Session 只接管 ReaderReady 交接和后续切章。
do
    local callback
    local cancelled = 0
    local source = {
        type = "chapter",
        openBookAsync = function(_, _, _, cb)
            local active = true
            callback = function(...)
                if active then cb(...) end
            end
            return { cancel = function()
                active = false
                cancelled = cancelled + 1
            end }
        end,
        prefetchChaptersAsync = function(_, _, _, from_idx, count)
            calls.prefetch = { from_idx = from_idx, count = count }
            return { cancel = function() calls.prefetch_cancelled = true end }
        end,
    }
    package.preload["apps/reader/readerui"] = function()
        return {
            instance = {
                switchDocument = function(_, path)
                    calls.switched_path = path
                end,
            },
        }
    end
    local identity = { source_id = "moon", stable_id = "chapters", source = source,
        book = { source_id = "moon", stable_id = "chapters", title = "章节书" } }
    resolved_source = source
    local toc = { { idx = 1 }, { idx = 2 } }
    stored_toc.chapters = toc
    local plugin = mkPlugin("/cache/1.html")
    Session.onReaderReady(plugin)

    Assert.eq(calls.prefetch.from_idx, 1)
    Assert.eq(calls.prefetch.count, 3)

    Assert.is_false(Session.onChapterBoundary(-1), "首章不能继续向前")
    Assert.is_true(Session.onChapterBoundary(1), "章末触发下一章")
    Assert.is_false(Session.onChapterBoundary(1), "请求在途时拒绝重复边界事件")
    callback(nil, "download failed")
    Assert.is_true(Session.gotoChapter(2), "失败后允许再次切章")

    -- 手动打开其他文档会取消旧切章任务并丢弃迟到回调。
    local manual_plugin = mkPlugin("/other/3.html")
    Session.onReaderReady(manual_plugin)
    Assert.eq(cancelled, 1)
    callback("/cache/2.html")
    Assert.is_nil(calls.switched_path)
    Assert.is_false(Session.gotoChapter(1))
    Session.onCloseDocument(manual_plugin)
    resolved_source = nil
end

-- 异步源返回目标章后，Session 切换文档并在新 ReaderReady 继续沿用目录。
do
    local toc = { { idx = 1 }, { idx = 2 } }
    local source = {
        type = "chapter",
        openBookAsync = function(_, _, opts, cb)
            local idx = opts.chapter_idx
            stored_toc.chapters = toc
            return asyncChapter("/cache/" .. idx .. ".html", cb)
        end,
        prefetchChaptersAsync = function(_, _, _, from_idx, count)
            calls.prefetch = { from_idx = from_idx, count = count }
            return { cancel = function() end }
        end,
    }
    local identity = { source_id = "moon", stable_id = "chapters", source = source,
        book = { source_id = "moon", stable_id = "chapters" } }
    resolved_source = source
    stored_toc.chapters = toc
    local function countPulls()
        local n = 0
        for _, entry in ipairs(calls.progress) do
            if entry[1] == "pull" then n = n + 1 end
        end
        return n
    end
    local plugin = mkPlugin("/cache/1.html")
    local pulls_before = countPulls()
    Session.onReaderReady(plugin)
    Assert.eq(countPulls(), pulls_before + 1, "冷打开只 pull 一次")
    Assert.is_true(Session.gotoChapter(2))
    Stubs.flush()
    Assert.eq(calls.switched_path, "/cache/2.html")
    plugin.ui.document.file = "/cache/2.html"
    local toc_reads_before_switch_ready = toc_reads
    Session.onReaderReady(plugin)
    Assert.eq(countPulls(), pulls_before + 1, "连续切章不应再 pull")
    Assert.eq(toc_reads, toc_reads_before_switch_ready, "连续切章复用已加载目录")
    Assert.len(Session.toc(), 2)

    -- 目录回跳上一章落到章首，不是章尾
    local events = {}
    plugin.ui.handleEvent = function(_, ev) events[#events + 1] = ev end
    Assert.is_true(Session.gotoChapter(1))
    Stubs.flush()
    Assert.eq(calls.switched_path, "/cache/1.html")
    plugin.ui.document.file = "/cache/1.html"
    Session.onReaderReady(plugin)
    Stubs.flush()
    local ev = events[#events]
    Assert.eq(ev.handler, "onGotoPage")
    Assert.eq(ev.args[1], 1)
    plugin.ui.handleEvent = nil

    Session.onCloseDocument(plugin)
    resolved_source = nil
end

-- .moon 外文档统一归 local，并按 local 属主源分发
do
    local plugin, emitted = mkPlugin("/other/plain.epub")
    local progress_before = #calls.progress
    Session.onReaderReady(plugin)
    Assert.not_nil(Session.current())
    Assert.eq(Session.current().identity.source_id, "local")
    Assert.eq(Session.current().identity.source.id, "local")
    Assert.eq(calls.tracker[#calls.tracker][1], "start")
    Assert.eq(calls.progress[progress_before + 1][1], "pull")
    Assert.eq(calls.reader[#calls.reader][1], "attach")
end

-- 注解事件只由活动 ReaderSession 以当前身份保存完整文档快照。
do
    local plugin = mkPlugin("/x/book.epub")
    plugin.ui.annotation = { annotations = { { text = "高亮" } } }
    Session.onReaderReady(plugin)
    Session.onAnnotationsModified(plugin, { { text = "变更描述" } })
    local saved = calls.notes[#calls.notes]
    Assert.eq(saved[1].stable_id, "b1")
    Assert.eq(saved[2], plugin.ui)
    Session.onCloseDocument(plugin)
end

-- ReaderReady 遇到整本书必须立即丢弃残留的章节会话。
do
    stored_toc.chapters = { { idx = 1 }, { idx = 2 } }
    Session.onReaderReady(mkPlugin("/cache/1.html"))
    local plugin = mkPlugin("/other/plain.epub")
    Session.onReaderReady(plugin)
    Assert.is_false(Session.gotoChapter(1), "整本书打开时清除旧章节会话")
    Session.onCloseDocument(plugin)
end

-- 库里没有路径登记的文件：弹 ConfirmBox 引导从桌面打开，ok 关文档，不建会话
do
    package.preload["ui/widget/confirmbox"] = function()
        return {
            new = function(_, opts)
                return opts
            end,
        }
    end
    local UIManager = require("ui/uimanager")
    local shown = {}
    local old_show = UIManager.show
    UIManager.show = function(_, widget)
        shown[#shown + 1] = widget
    end

    local plugin, emitted = mkPlugin("/.moon/cache/moon/book/unknown/1.html")
    stored_toc.chapters = { { idx = 1 } }
    Session.onReaderReady(mkPlugin("/cache/1.html"))
    local closed = 0
    plugin.ui.onClose = function()
        closed = closed + 1
    end
    Session.onReaderReady(plugin)
    Assert.is_nil(Session.current(), "拒开不建会话")
    Assert.is_false(Session.gotoChapter(1), "无法识别的文档也清除章节会话")
    Assert.eq(#shown, 1)
    Assert.eq(shown[1].text, "无法识别此书，请从 Book 桌面打开。")
    Assert.eq(shown[1].ok_text, "关闭文档")
    Assert.eq(shown[1].cancel_text, "仍要阅读")
    Assert.eq(#emitted, 0)
    shown[1].ok_callback()
    Assert.eq(closed, 1, "点 ok 调 ui:onClose()")
    Session.onCloseDocument(plugin)
    Assert.eq(#emitted, 0, "未知文档关闭时不通知当前源")
    UIManager.show = old_show
end

-- 有身份文档：建会话并快照页码/页数/百分比
do
    local plugin, emitted = mkPlugin("/x/book.epub")
    Session.onReaderReady(plugin)
    Assert.not_nil(Session.current())
    local cur = Session.current()
    Assert.eq(cur.identity.stable_id, "b1")
    Assert.eq(cur.page, 5)
    Assert.eq(cur.total_pages, 200)
    Assert.eq(cur.percent, 25)
    Assert.is_nil(Session.toc(), "整本书没有章节目录")
    Assert.is_nil(Session.chapterTitle(), "整本书无章节标题")
    Assert.eq(cur.identity.source.id, "moon", "属主源来自身份")
    -- 统计拿到的是内存身份（DB 写入异步，同 tick 查不到）
    local start_call = calls.tracker[#calls.tracker]
    Assert.eq(start_call[1], "start")
    Assert.eq(start_call[2].identity.stable_id, "b1")

    -- 翻页：更新快照 + 刷新 + 分发 page_changed
    Session.onPageChanged(plugin, 6)
    Assert.eq(Session.current().page, 6)
    Assert.eq(calls.reader[#calls.reader][1], "refresh")
    local ev = emitted[#emitted]
    Assert.eq(ev.ev, "page_changed")
    Assert.eq(ev.payload.identity.stable_id, "b1")
    Assert.eq(ev.payload.page, 6)
    Assert.eq(ev.payload.total_pages, 200)
    Assert.eq(ev.payload.percent, 25)

    -- 滚动视图同路径
    Session.onPageChanged(plugin, 7)
    Assert.eq(emitted[#emitted].payload.page, 7)

    -- 关文档：推进度/结清/通知源/清会话（真关书还会清进度冲突记忆）
    defer_tracker_stop = true
    local emitted_before_close = #emitted
    Session.onCloseDocument(plugin)
    Assert.eq(#emitted, emitted_before_close, "最后一段统计落库前不通知源")
    tracker_stop_done()
    tracker_stop_done = nil
    defer_tracker_stop = false
    Assert.is_nil(Session.current(), "关书清会话")
    Assert.eq(calls.progress[#calls.progress - 1][1], "sync")
    Assert.eq(calls.progress[#calls.progress][1], "clearConflicts")
    Assert.eq(calls.tracker[#calls.tracker][1], "stop")
    Assert.eq(emitted[#emitted].ev, "document_close")
    Assert.eq(calls.notes[#calls.notes][1].stable_id, "b1", "注解同步复用阅读身份")
    Assert.eq(calls.notes[#calls.notes][2], "sync", "注解保存成功后才触发同步")
    Assert.is_nil(Session.current(), "关闭文档清理阅读状态")

    -- 不活跃时翻页：统计照收，源不收事件
    local n = #emitted
    Session.onPageChanged(plugin, 8)
    Assert.eq(#emitted, n, "不活跃不分发")
    Assert.eq(calls.tracker[#calls.tracker][1], "onPage")
end

-- 章节文件：chapter_idx 只来自物理路径身份，目录只在活动章节会话可见。
do
    local toc = {}
    for i = 1, 10 do toc[i] = { idx = i, title = tostring(i) } end
    stored_toc.b2 = toc
    local plugin, emitted = mkPlugin("/other/9.html")
    Session.onReaderReady(plugin)
    Assert.not_nil(Session.current(), "章会话活跃")
    local cur = Session.current()
    Assert.eq(cur.identity.stable_id, "b2")
    Assert.eq(cur.identity.chapter_idx, 9)
    Assert.len(Session.toc(), 10)
    Assert.eq(Session.chapterTitle(), "9", "章节标题来自 toc title")
    Assert.eq(cur.identity.book.title, "旧章书")
    Assert.eq(cur.identity.source.id, "moon")
    Assert.eq(cur.percent, 75, "章节快照使用当前会话身份计算全书进度")
    Assert.eq(calls.progress_position_identity, cur.identity)
    Assert.is_nil(calls.chapter[#calls.chapter], "章节落点不再由 chapters 门面处理")
    Session.onCloseDocument(plugin)
    Assert.is_false(Session.gotoChapter(1), "真关书清除目录状态")
end

-- 按章阅读：拦截 KOReader 原生 EndOfBook 弹窗，改由会话切下一章。
do
    local end_dialog = 0
    local toc = { { idx = 1 }, { idx = 2 } }
    stored_toc.chapters = toc
    package.preload["apps/reader/readerui"] = function()
        return {
            instance = {
                switchDocument = function(_, path)
                    calls.switched_path = path
                end,
            },
        }
    end
    package.loaded["apps/reader/readerui"] = nil
    local source = {
        type = "chapter",
        openBookAsync = function(_, _, opts, cb)
            return asyncChapter("/cache/" .. opts.chapter_idx .. ".html", cb)
        end,
        prefetchChaptersAsync = function()
            return { cancel = function() end }
        end,
    }
    resolved_source = source
    local plugin = mkPlugin("/cache/1.html")
    plugin.ui.name = "ReaderUI"
    plugin.ui.status = {
        onEndOfBook = function()
            end_dialog = end_dialog + 1
        end,
    }
    Session.onReaderReady(plugin)
    Assert.is_true(plugin.ui._book_end_of_book_handler)
    Assert.is_true(plugin.ui.status.onEndOfBook(plugin.ui.status))
    Stubs.flush()
    Assert.eq(end_dialog, 0, "切章成功时不弹原生结束对话框")
    Assert.eq(calls.switched_path, "/cache/2.html")
    Session.onCloseDocument(plugin)
    resolved_source = nil
end

-- 已落盘章节文件冷打开时从数据库恢复目录和跨章导航。
do
    local source = {
        id = "moon",
        type = "chapter",
        openBookAsync = function()
            return { cancel = function() end }
        end,
    }
    resolved_source = source
    local plugin = mkPlugin("/other/3.html")
    Session.onReaderReady(plugin)
    Assert.not_nil(Session.current())
    Assert.len(Session.toc(), 10, "冷打开章节从 toc 表恢复目录")
    Assert.is_true(Session.gotoChapter(2))
    Session.onCloseDocument(plugin)
    resolved_source = nil
end

-- 换源后继续读旧书：源跟身份走（identity.source），不碰 current（串书修复）
do
    local plugin, emitted = mkPlugin("/x/book.epub")
    Session.onReaderReady(plugin)
    local cur = Session.current()
    Assert.eq(cur.identity.source.id, "moon", "源必须来自身份解析")
    -- 拉进度收到属主源
    local pull = calls.progress[#calls.progress]
    Assert.eq(pull[1], "pull")
    Assert.eq(pull[2].source_id, "moon")
    Session.onCloseDocument(plugin)
    local sync_call = calls.progress[#calls.progress - 1]
    Assert.eq(sync_call[1], "sync")
    Assert.eq(sync_call[2].source_id, "moon", "保存当前书后再同步属主源")
    Assert.eq(emitted[#emitted].source.id, "moon", "document_close 事件路由到属主源")
end

-- remainingSeconds：全书比例 × 历史时长线性外推；无会话或数据不足返回 nil
do
    local plugin, _ = mkPlugin("/x/book.epub")
    Session.onReaderReady(plugin)
    Assert.eq(Session.remainingSeconds(), 18000)
    Session.onCloseDocument(plugin)
    Assert.is_nil(Session.remainingSeconds())
end
do
    local plugin, _ = mkPlugin("/other/plain.epub")
    Session.onReaderReady(plugin)
    Assert.is_nil(Session.remainingSeconds())
end
do
    resolved_source = default_source
    stored_toc.chapters = { { idx = 1 }, { idx = 2 } }
    local plugin, _ = mkPlugin("/cache/1.html")
    Session.onReaderReady(plugin)
    Assert.eq(Session.remainingSeconds(), 2000)
    Session.onCloseDocument(plugin)
end

-- 清理：fake 经 package.preload 安装，runner 只清 package.loaded。
for _, name in ipairs({
    "book.store", "book.stats", "book.progress",
    "book.note",
    "ui.reader",
    "utils.db.stats",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "apps/reader/readerui",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["ui.reader.session"] = nil
