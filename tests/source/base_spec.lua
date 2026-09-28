--[[-- source.base：首页同步在后台进行，不阻塞本地首页数据。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
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

-- 源上报的真实步骤转成桌面事件；同步落下发 books_sync_done；被新一轮取代的旧请求上报丢弃。
local events = {}
desktop.onEvent = function(_, event, payload)
    events[#events + 1] = payload and table.concat({ event, payload.text, payload.done or "", payload.total or "" }, "|")
        or event
end
local pending = {}
source.syncBooksAsync = function(_, opts, cb)
    pending[#pending + 1] = { opts = opts, cb = cb }
    return { cancel = function() end }
end
source:onEvent("library_refresh_request", desktop)
local first = pending[#pending]
Assert.is_true(first.opts.force)
first.opts.on_progress("正在上传 a.epub", 1, 3)
Assert.eq(events[#events], "books_sync_progress|正在上传 a.epub|1|3")
-- 手动刷新进后台任务列表，步骤同步到任务快照。
local Tasks = require("tasks")
Assert.eq(#Tasks.tasks(), 1)
Assert.eq(Tasks.tasks()[1].label, "同步书架")
Assert.eq(Tasks.tasks()[1].text, "正在上传 a.epub")
source:onEvent("library_refresh_request", desktop)
local second = pending[#pending]
Assert.eq(#Tasks.tasks(), 1, "新一轮取代旧任务，不叠加")
local before = #events
first.opts.on_progress("旧请求", 2, 3)
first.cb({ skipped = true })
Assert.eq(#events, before, "旧请求的进度与完成都不上报")
second.cb({ skipped = true })
Assert.eq(events[#events], "books_sync_done")
Assert.is_false(desktop._books_sync_pending)
Assert.eq(#Tasks.tasks(), 0)

return true
