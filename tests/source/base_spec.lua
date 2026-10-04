---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- source.base：首页同步在后台进行，不阻塞本地首页数据。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end
local followed, rejected = {}, {}
package.preload["workers.ui.task_dialog"] = function()
    return {
        follow = function(task) followed[#followed + 1] = task end,
        rejected = function(reason, task) rejected[#rejected + 1] = { reason = reason, task = task } end,
    }
end

local SourceBase = require("source.base")
local sync_calls, stats_calls, stats_callbacks = 0, 0, {}
local source = setmetatable({
    id = "test",
    configured = function() return true end,
    capabilities = function() return { stats_pull = true } end,
    syncBooksAsync = function(_, _, cb)
        sync_calls = sync_calls + 1
        cb({ skipped = true })
        return { cancel = function() end }
    end,
    syncStatsAsync = function(_, _, cb)
        stats_calls = stats_calls + 1
        stats_callbacks[#stats_callbacks + 1] = cb
        return { cancel = function() end }
    end,
}, { __index = SourceBase })

-- 插件生命周期钩子默认空操作：不起同步，不碰插件。
for _, hook in ipairs({ "onCreate", "onSuspend", "onResume", "onExit" }) do
    Assert.is_nil(source[hook](source, {}))
end
Assert.eq(sync_calls, 0)
Assert.eq(stats_calls, 0)

local view_updates, refreshes = 0, 0
local desktop = {
    lifecycle = { state = "Resume" },
    source = source,
    tab = "home",
    library = { state = { books = { 1 } } },
    insight = { state = { has_data = true }, loaded = true },
    updateView = function() view_updates = view_updates + 1 end,
    onEvent = function(_, event)
        Assert.is_true(event ~= "home_refresh", "同步不得整页重建首页")
        if event == "stats_changed" or event == "shelf_changed" then refreshes = refreshes + 1 end
    end,
}
source:onEvent("home_open", desktop)
Assert.eq(view_updates, 0)
Assert.is_false(desktop._books_sync_pending)
Assert.eq(sync_calls, 1)
Assert.eq(stats_calls, 1)
Assert.is_true(desktop._stats_sync_pending)

-- 统计同步在飞时复用生命周期，不得重复发起。
source:onEvent("home_open", desktop)
Assert.eq(view_updates, 0)
Assert.eq(sync_calls, 2)
Assert.eq(stats_calls, 1)

-- 统计成功落库后，首页必须重新读取本地统计。
stats_callbacks[1]({ pulled = 2, pushed = 1 })
Assert.is_false(desktop._stats_sync_pending)
Assert.eq(refreshes, 1)
Assert.eq(view_updates, 0)

-- 唤醒事件的书架与统计分别节流；过期后统计才重新同步。
source._books_refresh_at = os.time()
source._stats_refresh_at = os.time() - 301
desktop.tab = "insight"
source:onEvent("desktop_resume", desktop)
Assert.eq(sync_calls, 2)
Assert.eq(stats_calls, 2)
stats_callbacks[2]({ pulled = 1, pushed = 0 })
Assert.is_false(desktop.insight.loaded)
Assert.is_nil(desktop.insight.state)
Assert.eq(refreshes, 2)
Assert.eq(view_updates, 1)

-- 新建桌面不沿用唤醒节流：首次可见必须立即同步书架和统计。
source._stats_refresh_at = os.time() - 301
desktop.tab = "home"
source:onEvent("desktop_open", desktop)
Assert.eq(sync_calls, 3)
Assert.eq(stats_calls, 3)
stats_callbacks[3]({ pulled = 1, pushed = 1 })
Assert.eq(refreshes, 3)
Assert.eq(view_updates, 1)

-- 统计无新增也无上报：本地数据未变，首页不重建。
source._stats_refresh_at = os.time() - 301
source:onEvent("desktop_open", desktop)
stats_callbacks[4]({ pulled = 0, pushed = 0 })
Assert.eq(refreshes, 3)

-- 书架同步失败：首页展示的是本地数据，不因失败重建。
source._stats_refresh_at = os.time()
source.syncBooksAsync = function(_, _, cb)
    cb(nil, "offline")
    return { cancel = function() end }
end
source:onEvent("desktop_open", desktop)
Assert.eq(refreshes, 3)

-- 书架对账计数全 0：不重建首页。
source.syncBooksAsync = function(_, _, cb)
    cb({ pulled = 0, pushed = 0, hidden = 0 })
    return { cancel = function() end }
end
source:onEvent("desktop_open", desktop)
Assert.eq(refreshes, 3)

-- 书架对账有数据：通知首页比对最近书架，由组件决定是否重建。
local last_event
desktop.onEvent = function(_, event) last_event = event end
source.syncBooksAsync = function(_, _, cb)
    cb({ pulled = 467, pushed = 0, hidden = 0 })
    return { cancel = function() end }
end
source:onEvent("desktop_open", desktop)
Assert.eq(last_event, "shelf_changed")

-- 手动刷新：进任务队列（sync 类）并前台跟随，源上报的真实步骤进任务快照。
desktop.onEvent = function() end
local pending, cancels = {}, 0
source.syncBooksAsync = function(_, opts, cb)
    pending[#pending + 1] = { opts = opts, cb = cb }
    return { cancel = function() cancels = cancels + 1 end }
end
source:onEvent("library_refresh_request", desktop)
local first = pending[#pending]
Assert.is_true(first.opts.force)
local Tasks = require("workers.tasks")
Assert.eq(#Tasks.tasks(), 1)
Assert.eq(Tasks.tasks()[1].kind, "sync")
Assert.len(followed, 1)
Assert.eq(followed[1], Tasks.get("books\0test"))
first.opts.on_progress("正在上传 a.epub", 1, 3)
Assert.eq(Tasks.tasks()[1].text, "正在上传 a.epub")
Assert.eq(Tasks.tasks()[1].count, 1)

-- 刷新中再点：拒绝入队并提示，不取消重来、不叠加、不动在飞状态。
source:onEvent("library_refresh_request", desktop)
Assert.len(pending, 1)
Assert.eq(cancels, 0)
Assert.len(followed, 1)
Assert.len(rejected, 1)
Assert.eq(rejected[1].reason, "running")
Assert.eq(rejected[1].task, followed[1])
Assert.is_true(desktop._books_sync_pending)
first.cb({ skipped = true })
Assert.is_false(desktop._books_sync_pending)
Assert.eq(#Tasks.tasks(), 0)

-- 自动后台同步在飞时手动刷新：取代它；旧请求迟到的进度与结果丢弃。
source:onEvent("desktop_open", desktop)
local auto = pending[#pending]
Assert.is_nil(auto.opts.force)
source:onEvent("library_refresh_request", desktop)
Assert.eq(cancels, 1)
local forced = pending[#pending]
Assert.is_true(forced.opts.force)
auto.opts.on_progress("旧请求", 2, 3)
auto.cb({ skipped = true })
Assert.is_true(desktop._books_sync_pending, "旧请求结果不落地")
Assert.is_nil(Tasks.tasks()[1].text)
forced.cb({ skipped = true })
Assert.is_false(desktop._books_sync_pending)
Assert.eq(#Tasks.tasks(), 0)

return true
