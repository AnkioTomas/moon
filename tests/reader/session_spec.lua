--[[--
reader.session 离线用例：身份自举 / 快照 / page_changed 分发 / 会话清理。

@module tests.reader.session_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local calls = { tracker = {}, progress = {}, chapter = {}, reader = {}, book = {} }
local defer_tracker_stop = false
local tracker_stop_done
local resolved_source
local stored_toc = {}
local toc_reads = 0
local book_fraction = 0.25
local auto_mark_read = false
local emitted = {}
--- 测试源的 onEvent：记到最近一次 mkPlugin 返回的 emitted。
local SourceStub = { __index = { onEvent = function(self, ev, payload)
    emitted[#emitted + 1] = { ev = ev, payload = payload, source = self }
end } }
---@param source table
---@return table
local function withEvents(source)
    if not getmetatable(source) then setmetatable(source, SourceStub) end
    return source
end
local default_source = {
    id = "moon",
    type = "book",
    putProgressAsync = function() end,
    syncProgressAsync = function(_, opts, cb)
        calls.progress[#calls.progress + 1] = { "sync", opts.identity, opts.dirty_only }
        if cb then cb({}) end
    end,
    syncNotesAsync = function(_, opts, cb)
        calls.notes = calls.notes or {}
        calls.notes[#calls.notes + 1] = { opts.identity, opts.dirty_only and "dirty" or "sync" }
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
    local function identityFor(path)
            if path == "/x/book.epub" then
                return {
                    source_id = "moon",
                    stable_id = "b1",
                    chapter_idx = nil,
                    book = { title = "整本书" },
                    source = withEvents(resolved_source or default_source),
                }
            end
            if path == "/other/3.html" then
                return {
                    source_id = "moon",
                    stable_id = "b2",
                    chapter_idx = 3,
                    book = { title = "旧章书" },
                    source = withEvents(resolved_source or chapter_default_source),
                }
            end
            if path == "/other/9.html" then
                return {
                    source_id = "moon",
                    stable_id = "b2",
                    chapter_idx = 9,
                    book = { title = "旧章书" },
                    source = withEvents(resolved_source or chapter_default_source),
                }
            end
            if path == "/other/plain.epub" then
                return {
                    source_id = "local",
                    stable_id = "/other/plain.epub",
                    chapter_idx = nil,
                    book = { title = "plain" },
                    source = withEvents({ id = "local", type = "book" }),
                }
            end
            if path == "/cache/1.html" or path == "/cache/2.html" then
                return {
                    source_id = "moon",
                    stable_id = "chapters",
                    chapter_idx = path == "/cache/1.html" and 1 or 2,
                    book = { title = "章节书" },
                    source = withEvents(resolved_source or chapter_default_source),
                }
            end
            return nil
        end
        return {
            identityFor = identityFor,
            ensureIdentity = identityFor,
        }
end
package.preload["source.toc"] = function()
    return {
        read = function(_source_id, stable_id)
            toc_reads = toc_reads + 1
            return stored_toc[stable_id]
        end,
    }
end

local injected = {}
package.preload["reader.prefs"] = function()
    return {
        inject = function(doc_settings) injected[#injected + 1] = "prefs:" .. doc_settings.id end,
        apply = function() end,
        captureAndSave = function() end,
    }
end

package.preload["book.books_db"] = function()
    return {
        markReadAutomatically = function(source_id, stable_id)
            calls.book[#calls.book + 1] = { "auto_read", source_id, stable_id }
            return true
        end,
        markReadComplete = function(source_id, stable_id)
            calls.book[#calls.book + 1] = { "complete", source_id, stable_id }
            return true
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function()
            return { auto_mark_read_at_99 = auto_mark_read }
        end,
    }
end

package.preload["reader.session.stats"] = function()
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

package.preload["reader.session.note"] = function()
    return {
        save = function(ui, identity, changed, cb)
            calls.notes = calls.notes or {}
            calls.notes[#calls.notes + 1] = { identity, ui, changed }
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
    }
end

package.preload["reader.session.progress"] = function()
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
            local fraction = identity and identity.chapter_idx and 0.75 or book_fraction
            return {
                fraction = fraction,
                chapter_idx = identity and identity.chapter_idx,
                chapter_fraction = identity and identity.chapter_idx and 0.5 or nil,
            }
        end,
    }
end

package.loaded["reader.page"] = nil
package.preload["reader.page"] = function()
    return {
        onCreate = function(plugin)
            calls.reader[#calls.reader + 1] = { "onCreate" }
        end,
    }
end
local bar_apply_count = 0
local current_resume_plugin
-- 扩展点（真机由状态栏 feature 登记）
local Ext = require("utils.extension")
Ext.add("reader.preferences", function(ui)
    bar_apply_count = bar_apply_count + 1
    Assert.eq(ui, current_resume_plugin and current_resume_plugin.ui)
end)
Ext.add("reader.doc_settings", function(doc_settings) injected[#injected + 1] = "bars:" .. doc_settings.id end)
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) require("ui/uimanager"):show(o) end
local end_dialog_identity
package.preload["reader.end_dialog"] = function()
    return {
        show = function(_, identity)
            end_dialog_identity = identity
        end,
    }
end

local cover_saves = {}
package.preload["book.cover"] = function()
    return {
        save = function(doc, target) cover_saves[#cover_saves + 1] = { doc = doc, target = target } end,
    }
end

package.preload["book.stats_db"] = function()
    return {
        summaryByBook = function(source_id, stable_id)
            if source_id == "moon" and (stable_id == "b1" or stable_id == "chapters") then
                return { total_seconds = 6000, pages = 100, last_read = 0 }
            end
            return { total_seconds = 0, pages = 0, last_read = 0 }
        end,
    }
end

local Session = require("reader.session")

local function asyncChapter(path, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if not cancelled then cb(path) end
    end)
    return { cancel = function() cancelled = true end }
end

---@param path string
local function mkPlugin(path)
    emitted = {}
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
    }
    return plugin, emitted
end

-- 唤醒阅读器时必须重新应用顶栏/底栏偏好，防止 KOReader 恢复流程覆盖关闭状态。
do
    local plugin = mkPlugin("/other/plain.epub")
    current_resume_plugin = plugin
    Session.onResume(plugin)
    Assert.eq(bar_apply_count, 1)
    current_resume_plugin = nil
end

-- 首次路径由源解析；Session 只接管 ReaderReady 交接和后续切章。
do
    local callback
    local cancelled, opened = 0, 0
    local source = {
        type = "chapter",
        openBookAsync = function(_, _, _, cb)
            opened = opened + 1
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

    -- 本章：无定位点不重开；带定位点（目录锚点 / 笔记）原地跳转
    local events = {}
    plugin.ui.handleEvent = function(_, ev) events[#events + 1] = ev end
    Assert.is_false(Session.gotoChapter(1))
    Assert.is_true(Session.gotoChapter(1, { xpointer = "#id_3" }))
    Assert.eq(opened, 0)
    Assert.len(events, 1)
    Assert.eq(events[1].handler, "onGotoXPointer")
    Assert.eq(events[1].args[1], "#id_3")

    local ChapterMode = require("reader.session.chapter")
    Assert.is_false(ChapterMode.onChapterBoundary(Session.current(), -1), "首章不能继续向前")
    Assert.is_true(ChapterMode.onChapterBoundary(Session.current(), 1), "章末触发下一章")
    Assert.eq(opened, 1)
    -- 在途期间重复边界事件仍算「已处理」（吞掉原生 EndOfBook 弹窗），但不再发起第二次请求
    Assert.is_true(ChapterMode.onChapterBoundary(Session.current(), 1), "请求在途时锁住重复边界事件")
    Assert.eq(opened, 1, "在途时不得重复发起切章请求")
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
    local UIManager = require("ui/uimanager")
    local old_show, old_close = UIManager.show, UIManager.close
    local transition_notice, transition_closes = nil, 0
    UIManager.show = function(self, widget)
        if widget and widget.text == "正在切换章节，请稍候…" then
            transition_notice = widget
        end
        return old_show(self, widget)
    end
    UIManager.close = function(self, widget)
        if widget == transition_notice then transition_closes = transition_closes + 1 end
        return old_close(self, widget)
    end
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
    Assert.not_nil(transition_notice)
    Assert.eq(transition_closes, 0, "新 ReaderReady 前切章提示继续显示")
    plugin.ui.document.file = "/cache/2.html"
    local toc_reads_before_switch_ready = toc_reads
    Session.onReaderReady(plugin)
    Assert.eq(transition_closes, 1, "目标章节 ReaderReady 后必须关闭切章提示")
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
    UIManager.show, UIManager.close = old_show, old_close
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
    -- 整本书冷打开：先按本地记录回落位置，再拉云端对比。
    Assert.eq(calls.progress[progress_before + 1][1], "applyLocalPending")
    Assert.eq(calls.progress[progress_before + 2][1], "pull")
    Assert.eq(calls.reader[#calls.reader][1], "onCreate")
end

-- 注解事件：落盘后有网即 dirty push。
do
    local plugin = mkPlugin("/x/book.epub")
    plugin.ui.annotation = { annotations = { { text = "高亮" } } }
    Session.onReaderReady(plugin)
    local notes_before = #(calls.notes or {})
    local changed = { { text = "变更描述" }, nb_highlights_added = -1, index_modified = -3 }
    Session.onAnnotationsModified(plugin, changed)
    Stubs.flush()
    local saved = calls.notes[notes_before + 1]
    Assert.eq(saved[1].stable_id, "b1")
    Assert.eq(saved[2], plugin.ui)
    Assert.eq(saved[3], changed, "变更描述要透传给 SessionNote.save（删除墓碑靠它判 index_modified）")
    local pushed = calls.notes[notes_before + 2]
    Assert.eq(pushed[1].stable_id, "b1")
    Assert.eq(pushed[2], "dirty")
    Session.onCloseDocument(plugin)
end

-- 注解事件离线：只落盘，不 push，也不走 runWhenOnline 弹联网提示。
do
    local NetworkMgr = require("ui/network/manager")
    local old_connected, old_run = NetworkMgr.isConnected, NetworkMgr.runWhenOnline
    local prompted = false
    NetworkMgr.isConnected = function() return false end
    NetworkMgr.runWhenOnline = function() prompted = true end
    local plugin = mkPlugin("/x/book.epub")
    plugin.ui.annotation = { annotations = { { text = "高亮" } } }
    Session.onReaderReady(plugin)
    local notes_before = #(calls.notes or {})
    Session.onAnnotationsModified(plugin, { { text = "变更描述" } })
    Stubs.flush()
    Assert.eq(calls.notes[notes_before + 1][2], plugin.ui)
    Assert.is_nil(calls.notes[notes_before + 2], "离线不 push")
    Assert.is_false(prompted, "离线不弹联网提示")
    NetworkMgr.isConnected, NetworkMgr.runWhenOnline = old_connected, old_run
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

-- 库里没有路径登记的文件：弹 Confirm 引导从桌面打开，ok 关文档，不建会话
do
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
    Assert.eq(shown[1].text, "无法识别此书，请从月读打开。")
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
    local UIManager = require("ui/uimanager")
    local old_dirty, dirtied = UIManager.setDirty, nil
    plugin.ui.dialog = {}
    UIManager.setDirty = function(_self, widget) dirtied = widget end
    Session.onPageUpdate(plugin, 6)
    UIManager.setDirty = old_dirty
    Assert.eq(Session.current().page, 6)
    Assert.is_true(dirtied == plugin.ui.dialog, "翻页刷新阅读窗口")
    local ev = emitted[#emitted]
    Assert.eq(ev.ev, "page_changed")
    Assert.eq(ev.payload.identity.stable_id, "b1")
    Assert.eq(ev.payload.page, 6)
    Assert.eq(ev.payload.total_pages, 200)
    Session.onPosUpdate(plugin, 1234, 7)
    Assert.eq(Session.current().page, 7, "滚动视图按页码走同一条路径")
    Session.onPageUpdate(plugin, 6)
    Assert.eq(ev.payload.percent, 25)

    -- 滚动视图同路径
    Session.onPageUpdate(plugin, 7)
    Assert.eq(emitted[#emitted].payload.page, 7)

    local book_calls = #calls.book
    book_fraction = 0.989
    Session.onPageUpdate(plugin, 198)
    Assert.eq(#calls.book, book_calls, "98.9% 不自动标记已读")
    book_fraction = 0.99
    Session.onPageUpdate(plugin, 199)
    Assert.eq(#calls.book, book_calls, "默认关闭时 99% 不自动标记已读")
    auto_mark_read = true
    Session.onPageUpdate(plugin, 199)
    Assert.eq(calls.book[#calls.book][1], "auto_read", "99% 自动标记已读")
    Assert.eq(cur.identity.book.read_state, 1)
    cur.identity.book.read_state = 2
    auto_mark_read = false
    book_fraction = 1
    Session.onPageUpdate(plugin, 200)
    Assert.eq(calls.book[#calls.book][1], "complete", "100% 必须覆盖手动未读")
    -- 没有 book 缓存可回写：末页反复翻页只写一次库。
    local saved_book = cur.identity.book
    cur.identity.book = nil
    local n = #calls.book
    Session.onPageUpdate(plugin, 200)
    Session.onPageUpdate(plugin, 200)
    Assert.eq(#calls.book, n + 1, "末页不在每次翻页时重复写库")
    cur.identity.book = saved_book
    Assert.eq(cur.identity.book.read_state, 1)
    book_fraction = 0.25

    -- 阅读中唤醒：通知源重启休眠时停掉的定时任务（微信时长心跳），带当前位置
    local emitted_before_resume = #emitted
    current_resume_plugin = plugin
    Session.onResume(plugin)
    current_resume_plugin = nil
    Assert.eq(#emitted, emitted_before_resume + 1)
    Assert.eq(emitted[#emitted].ev, "reading_resumed")
    Assert.eq(emitted[#emitted].payload.identity.stable_id, "b1")
    Assert.not_nil(emitted[#emitted].payload.position)

    -- 关文档：推进度/结清/通知源/清会话（真关书还会清进度冲突记忆）
    defer_tracker_stop = true
    local emitted_before_close = #emitted
    Session.onCloseDocument(plugin)
    Assert.eq(calls.progress[#calls.progress][1], "clearConflicts")
    Assert.is_true(calls.progress[#calls.progress - 1][1] ~= "sync",
        "时长推完之前不推进度：微信时长上报会写云端位置")
    tracker_stop_done()
    tracker_stop_done = nil
    defer_tracker_stop = false
    Assert.is_nil(Session.current(), "关书清会话")
    Assert.eq(calls.progress[#calls.progress][1], "sync")
    Assert.is_true(calls.progress[#calls.progress][3],
        "关书进度只能上传，不能立即回拉旧云端值")
    Assert.eq(calls.tracker[#calls.tracker][1], "stop")
    Assert.eq(#emitted, emitted_before_close + 1, "关书只给源发 reading_stopped")
    Assert.eq(emitted[#emitted].ev, "reading_stopped")
    Assert.eq(calls.notes[#calls.notes][1].stable_id, "b1", "注解同步复用阅读身份")
    Assert.eq(calls.notes[#calls.notes][2], "dirty", "关书注解只推脏，完整 pull 留给下次开书")
    Assert.is_nil(Session.current(), "关闭文档清理阅读状态")

    -- 不活跃时翻页：统计照收，源不收事件
    local n = #emitted
    Session.onPageUpdate(plugin, 8)
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

-- 已停在末页的文档 ReaderReady 后无需再翻页，也必须收敛为已读。
do
    local plugin = mkPlugin("/x/book.epub")
    book_fraction = 1
    Session.onReaderReady(plugin)
    Assert.eq(calls.book[#calls.book][1], "complete")
    Assert.eq(Session.current().identity.book.read_state, 1)
    book_fraction = 0.25
    Session.onCloseDocument(plugin)
end

-- 目录过期/缺失时 afterBootstrap 必须走 loadTocAsync。
do
    stored_toc.chapters = nil
    local loaded
    local source = {
        type = "chapter",
        loadTocAsync = function(_, identity, cb)
            loaded = identity.stable_id
            cb({ { idx = 1, title = "新" }, { idx = 2 } })
            return { cancel = function() end }
        end,
        prefetchChaptersAsync = function()
            return { cancel = function() end }
        end,
        putProgressAsync = default_source.putProgressAsync,
        syncProgressAsync = default_source.syncProgressAsync,
        syncNotesAsync = default_source.syncNotesAsync,
        syncStatsAsync = default_source.syncStatsAsync,
    }
    resolved_source = source
    local plugin = mkPlugin("/cache/1.html")
    Session.onReaderReady(plugin)
    Assert.eq(loaded, "chapters")
    Assert.len(Session.toc(), 2)
    Assert.eq(Session.toc()[1].title, "新")
    Session.onCloseDocument(plugin)
    resolved_source = nil
end

-- 属主源已不在（第三方源插件被卸载）：已落盘的章节照常打开，不给源发事件、不崩。
do
    local Store = require("book.store")
    local original = Store.ensureIdentity
    Store.ensureIdentity = function(path)
        local id = original(path)
        id.source = nil
        return id
    end
    stored_toc.chapters = { { idx = 1 }, { idx = 2 } }
    local plugin = mkPlugin("/cache/1.html")
    Session.onReaderReady(plugin)
    Stubs.flush()
    Assert.not_nil(Session.current())
    Assert.is_nil(Session.current().identity.source)
    Assert.not_nil(Session.current().chapter)
    Session.onCloseDocument(plugin)
    Store.ensureIdentity = original
end

-- 真正 EndOfBook 是 100% 完成兜底，即使快照比例不足且用户手动标过未读。
do
    local plugin = mkPlugin("/x/book.epub")
    plugin.ui.status = { onEndOfBook = function() end }
    book_fraction = 0.95
    Session.onReaderReady(plugin)
    Session.current().identity.book.read_state = 2
    Assert.is_true(plugin.ui.status.onEndOfBook(plugin.ui.status))
    Assert.eq(calls.book[#calls.book][1], "complete")
    Assert.eq(end_dialog_identity.stable_id, "b1")
    book_fraction = 0.25
    Session.onCloseDocument(plugin)
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
    Assert.len(Session.toc(), 10, "冷打开章节从 books.toc 恢复目录")
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

-- 整书打开：下一拍用已打开的文档补本地封面（云端没封面的书靠它）；章节文件没有封面可取，不碰。
do
    resolved_source = default_source
    local Paths = require("utils.paths")
    Stubs.flush()
    cover_saves = {}
    local plugin = mkPlugin("/x/book.epub")
    Session.onReaderReady(plugin)
    Stubs.flush()
    Assert.len(cover_saves, 1)
    Assert.eq(cover_saves[1].doc, plugin.ui.document)
    Assert.eq(cover_saves[1].target, Paths.coverPath("b1", "moon"))
    Session.onCloseDocument(plugin)

    -- 下一拍前文档已换掉：放弃，不对着旧文档取图。
    cover_saves = {}
    plugin = mkPlugin("/x/book.epub")
    Session.onReaderReady(plugin)
    plugin.ui.document = { file = "/x/other.epub" }
    Stubs.flush()
    Assert.len(cover_saves, 0)
    plugin.ui.document = { file = "/x/book.epub", getPageCount = function() return 200 end }
    Session.onCloseDocument(plugin)

    cover_saves = {}
    stored_toc.chapters = { { idx = 1 }, { idx = 2 } }
    plugin = mkPlugin("/cache/1.html")
    Session.onReaderReady(plugin)
    Stubs.flush()
    Assert.len(cover_saves, 0)
    Session.onCloseDocument(plugin)
end

-- DocSettingsLoad：读 sidecar 前先写全书排版，再写状态栏偏好
Session.onDocSettingsLoad({}, { id = "doc" }, {})
Assert.eq(table.concat(injected, ","), "prefs:doc,bars:doc")

-- 按章文档把 sidecar / 文档属性改成书名，旧缓存 <title> 是章名也不影响认书
do
    local saved
    local doc_settings = {
        id = "chapter-title",
        readSetting = function(_, key) return key == "doc_props" and {} or nil end,
        saveSetting = function(_, key, value) if key == "doc_props" then saved = value end end,
    }
    local document = { file = "/other/3.html", doc_props = { title = "夏" } }
    Session.onDocSettingsLoad({}, doc_settings, document)
    Assert.eq(saved.title, "旧章书")
    Assert.eq(saved.display_title, "旧章书")
    Assert.eq(document.doc_props.title, "旧章书")
end

-- 清理：fake 经 package.preload 安装，runner 只清 package.loaded。
for _, name in ipairs({
    "book.store", "reader.session.stats", "reader.session.progress",
    "reader.session.note", "book.cover",
    "reader.page",
    "book.books_db",
    "utils.settings",
    "book.stats_db",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "reader.end_dialog",
    "apps/reader/readerui",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["reader.session"] = nil
