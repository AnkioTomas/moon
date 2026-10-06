---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- desktop.sync：桌面可见后台同步、图书馆强制刷新、未配置引导。 --]]

local Assert = require("support.assert")

local followed, rejected = {}, {}
package.preload["workers.ui.task_dialog"] = function()
    return {
        follow = function(task) followed[#followed + 1] = task end,
        rejected = function(reason, task) rejected[#rejected + 1] = { reason = reason, task = task } end,
    }
end
local settings = {}
package.preload["desktop.pages.setting.source"] = function()
    return { loadSetting = function(id) return settings[id] end }
end
local Themed = require("support.theme_stubs")
Themed.install()

local Sync = require("desktop.sync")
local SourceBase = require("source.base")
local Tasks = require("workers.tasks")

local sync_calls, stats_calls, stats_callbacks = 0, 0, {}
local source = setmetatable({
    id = "test",
    name = "Test",
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
    source = source,
    tab = "home",
    updateView = function() view_updates = view_updates + 1 end,
    onEvent = function(self, event, payload)
        Assert.is_true(event ~= "home_refresh", "同步不得整页重建首页")
        if event == "stats_changed" or event == "shelf_changed" then refreshes = refreshes + 1 end
        if event == "shelf_sync_failed" then self.sync_err = payload end
    end,
}

-- 桌面可见：书架与统计都在后台同步，不重建页面。
Sync.open(desktop)
Assert.eq(view_updates, 0)
Assert.is_false(desktop._books_sync_pending)
Assert.eq(sync_calls, 1)
Assert.eq(stats_calls, 1)
Assert.is_true(desktop._stats_sync_pending)

-- 统计同步在飞时不得重复发起；书架照常同步。
Sync.open(desktop)
Assert.eq(sync_calls, 2)
Assert.eq(stats_calls, 1)

-- 统计成功落库后，首页必须重新读取本地统计。
stats_callbacks[1]({ pulled = 2, pushed = 1 })
Assert.is_false(desktop._stats_sync_pending)
Assert.eq(refreshes, 1)
Assert.eq(view_updates, 0)

-- 统计 5 分钟节流：刚同步过不再发起。
Sync.open(desktop)
Assert.eq(stats_calls, 1)

-- 手动刷新不受节流；在洞察页时通知统计已变并重绘。
desktop.tab = "insight"
Sync.refresh(desktop)
Assert.eq(stats_calls, 2)
stats_callbacks[2]({ pulled = 1, pushed = 0 })
Assert.eq(refreshes, 2)
Assert.eq(view_updates, 1)
desktop.tab = "home"

-- 统计无新增也无上报：本地数据未变，首页不重建。
Sync.refresh(desktop)
stats_callbacks[3]({ pulled = 0, pushed = 0 })
Assert.eq(refreshes, 2)

-- 以下只看书架：让统计停在飞行中，不再干扰计数。
Sync.refresh(desktop)
Assert.is_true(desktop._stats_sync_pending)

-- 书架同步失败：首页展示的是本地数据，不因失败重建。
source.syncBooksAsync = function(_, _, cb)
    cb(nil, "offline")
    return { cancel = function() end }
end
Sync.open(desktop)
Assert.eq(refreshes, 2)

-- 书架同步失败：错误以事件广播，由图书馆自己决定是否显示。
desktop.tab = "library"
Sync.open(desktop)
Assert.eq(desktop.sync_err, "offline")
desktop.tab = "home"

-- 书架对账计数全 0：不重建首页。
source.syncBooksAsync = function(_, _, cb)
    cb({ pulled = 0, pushed = 0, hidden = 0 })
    return { cancel = function() end }
end
Sync.open(desktop)
Assert.eq(refreshes, 2)

-- 书架对账有数据：通知首页比对最近书架，由组件决定是否重建。
local last_event
desktop.onEvent = function(_, event) last_event = event end
source.syncBooksAsync = function(_, _, cb)
    cb({ pulled = 467, pushed = 0, hidden = 0 })
    return { cancel = function() end }
end
Sync.open(desktop)
Assert.eq(last_event, "shelf_changed")

-- 手动刷新：进任务队列（sync 类）并前台跟随，源上报的真实步骤进任务快照。
desktop.onEvent = function() end
for i = #followed, 1, -1 do followed[i] = nil end
Assert.eq(#Tasks.tasks(), 0)
local pending, cancels = {}, 0
source.syncBooksAsync = function(_, opts, cb)
    pending[#pending + 1] = { opts = opts, cb = cb }
    return { cancel = function() cancels = cancels + 1 end }
end
Sync.refresh(desktop)
local first = pending[#pending]
Assert.is_true(first.opts.force)
Assert.eq(#Tasks.tasks(), 1)
Assert.eq(Tasks.tasks()[1].kind, "sync")
Assert.len(followed, 1)
Assert.eq(followed[1], Tasks.get("books\0test"))
first.opts.on_progress("正在上传 a.epub", 1, 3)
Assert.eq(Tasks.tasks()[1].text, "正在上传 a.epub")
Assert.eq(Tasks.tasks()[1].count, 1)

-- 刷新中再点：拒绝入队并提示，不取消重来、不叠加、不动在飞状态。
Sync.refresh(desktop)
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
Sync.open(desktop)
local auto = pending[#pending]
Assert.is_nil(auto.opts.force)
Sync.refresh(desktop)
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

-- 换源后旧源的结果不落到新源的页面上。
local other = setmetatable({ id = "other", configured = function() return true end }, { __index = SourceBase })
Sync.open(desktop)
local stale = pending[#pending]
desktop.source = other
local stale_events = 0
desktop.onEvent = function() stale_events = stale_events + 1 end
stale.cb({ pulled = 1, pushed = 0, hidden = 0 })
Assert.is_false(desktop._books_sync_pending)
Assert.eq(stale_events, 0)
desktop.source = source

-- 未配置：后台打开静默跳过；手动刷新说明原因，源有设置入口就给直达按钮。
local calls_before = #pending
source.configured = function() return false end
Sync.open(desktop)
Assert.eq(#pending, calls_before)
Assert.is_nil(Themed.last("confirm"))

local opened_with
settings.test = { open = function(plugin) opened_with = plugin end }
desktop.plugin = {}
Sync.refresh(desktop)
Assert.eq(#pending, calls_before)
local confirm = Themed.last("confirm")
Assert.eq(confirm.text, "请先完成数据源设置，再刷新书库。")
Assert.eq(confirm.ok_text, "立即设置")
confirm.ok_callback()
Assert.eq(opened_with, desktop.plugin)

-- 源没有设置入口：只提示，不给按钮。
settings.test = nil
Sync.refresh(desktop)
Assert.eq(Themed.last("toast").text, "请先完成数据源设置，再刷新书库。")

return true
