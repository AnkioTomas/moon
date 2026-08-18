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
        ensureIdentity = function(path)
            if path == "/x/book.epub" then
                return { ref = { source_id = "moon", stable_id = "b1" }, chapter_idx = nil }
            end
            if path == "/other/3.html" then
                return { ref = { source_id = "moon", stable_id = "b2" }, chapter_idx = 3 }
            end
            if path == "/other/plain.epub" then
                return {
                    ref = { source_id = "local", stable_id = "/other/plain.epub" },
                    chapter_idx = nil,
                }
            end
            return nil
        end,
    }
end

-- 属主源工厂：记录 create 调用，按 id 返回非活跃实例
local registry_created = {}
package.preload["source.registry"] = function()
    return {
        create = function(id)
            registry_created[#registry_created + 1] = id
            return { id = id }
        end,
    }
end

package.preload["stats.tracker"] = function()
    return {
        start = function(ui, identity)
            calls.tracker[#calls.tracker + 1] = { "start", ui, identity }
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
        clearConflicts = function()
            calls.progress[#calls.progress + 1] = { "clearConflicts" }
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
            return true -- 真关书（非切章）
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
        closeToolbar = function()
            calls.reader[#calls.reader + 1] = { "closeToolbar" }
        end,
    }
end

local Session = require("ui.reader.session")

---@param path string
---@param current_id string|nil 当前活跃源 id（缺省 moon）
local function mkPlugin(path, current_id)
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
            return { id = current_id or "moon" }
        end,
        emitToSource = function(_, ev, payload, source)
            emitted[#emitted + 1] = { ev = ev, payload = payload, source = source }
        end,
    }
    return plugin, emitted
end

-- .moon 外文档统一归 local，并按 local 属主源分发
do
    local plugin, emitted = mkPlugin("/other/plain.epub")
    Session.onReaderReady(plugin)
    Assert.is_true(Session.isActive())
    Assert.eq(Session.current().ref.source_id, "local")
    Assert.eq(Session.current().source.id, "local")
    Assert.eq(calls.tracker[1][1], "start")
    Assert.eq(calls.progress[1][1], "pull")
    Assert.eq(calls.reader[#calls.reader][1], "attach")
    Assert.eq(emitted[#emitted].ev, "reader_ready")
    Assert.eq(emitted[#emitted].source.id, "local")
    registry_created = {}
end

-- .moon 内未知文件不是本地书：提示从 Book 桌面打开，且不分发源事件
do
    package.preload["utils.paths"] = function()
        return {
            isMoonPath = function(path)
                return path == "/.moon/cache/moon/book/unknown/1.html"
            end,
        }
    end
    package.loaded["utils.paths"] = nil
    package.preload["ui/widget/infomessage"] = function()
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
    Session.onReaderReady(plugin)
    Assert.is_false(Session.isActive())
    Assert.eq(#shown, 1)
    Assert.eq(shown[1].text, "请从 Book 桌面打开此书")
    Assert.eq(#emitted, 0)
    Session.onCloseDocument(plugin)
    Assert.eq(#emitted, 0, "未知 .moon 文档关闭时不通知当前源")
    UIManager.show = old_show
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
    Assert.eq(cur.source.id, "moon", "current 即属主源时直接用 current")
    Assert.eq(#registry_created, 0, "同源不必另建实例")
    -- 统计拿到的是内存身份（DB 写入异步，同 tick 查不到）
    local start_call = calls.tracker[#calls.tracker]
    Assert.eq(start_call[1], "start")
    Assert.eq(start_call[3].ref.stable_id, "b1")

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

    -- 关文档：推进度/结清/通知源/清会话（真关书还会清进度冲突记忆）
    Session.onCloseDocument(plugin)
    Assert.is_false(Session.isActive(), "关书清会话")
    Assert.eq(calls.reader[#calls.reader][1], "closeToolbar")
    Assert.eq(calls.progress[#calls.progress - 1][1], "push")
    Assert.eq(calls.progress[#calls.progress][1], "clearConflicts")
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

-- 换源后继续读旧书：源跟 ref 走（属主源），不许用 current（串书修复）
do
    registry_created = {}
    local plugin, emitted = mkPlugin("/x/book.epub", "wechat") -- current=wechat，书是 moon:b1
    Session.onReaderReady(plugin)
    local cur = Session.current()
    Assert.eq(cur.source.id, "moon", "源必须按 ref.source_id 解析")
    Assert.eq(registry_created[#registry_created], "moon", "非活跃属主源经 registry.create 建实例")
    -- 拉进度收到属主源而不是 current
    local pull = calls.progress[#calls.progress]
    Assert.eq(pull[1], "pull")
    Assert.eq(pull[2].id, "moon", "pull 不许拿 wechat 拉 moon 的书")
    Assert.eq(emitted[#emitted].source.id, "moon", "reader_ready 事件路由到属主源")
    Session.onCloseDocument(plugin)
    local push = calls.progress[#calls.progress - 1]
    Assert.eq(push[1], "push")
    Assert.eq(push[2].id, "moon", "push 不许把 moon 的书推给 wechat")
    Assert.eq(emitted[#emitted].source.id, "moon", "document_close 事件路由到属主源")
end

-- 清理：fake 经 package.preload 安装，runner 只清 package.loaded，
-- 不卸会污染后续 spec（如 stats/tracker_spec 需要真 stats.tracker）
for _, name in ipairs({
    "book.store", "stats.tracker", "book.progress",
    "chapters.init", "chapters.patches", "ui.reader", "source.registry",
    "utils.paths", "ui/widget/infomessage",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["ui.reader.session"] = nil
