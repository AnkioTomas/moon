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

local rebuilds, refreshes = 0, 0
local desktop = {
    source = source,
    tab = "home",
    rebuild = function() rebuilds = rebuilds + 1 end,
    refreshHome = function() refreshes = refreshes + 1 end,
}
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 0)
Assert.is_false(desktop._books_sync_pending)
Assert.eq(sync_calls, 1)
Assert.eq(stats_calls, 1)
Assert.is_true(desktop._stats_sync_pending)

-- 统计同步在飞时复用生命周期，不得重复发起。
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 0)
Assert.eq(sync_calls, 2)
Assert.eq(stats_calls, 1)

-- 统计成功落库后，首页必须重新读取本地统计。
stats_callbacks[1]({ pulled = 2, pushed = 1 })
Assert.is_false(desktop._stats_sync_pending)
Assert.eq(refreshes, 1)
Assert.eq(rebuilds, 0)

-- 唤醒事件受书架节流约束，但统计仍按同一生命周期双向同步。
source._books_refresh_at = os.time()
desktop.tab = "stats"
source:onEvent("desktop_resume", desktop)
Assert.eq(sync_calls, 2)
Assert.eq(stats_calls, 2)
stats_callbacks[2]({ pulled = 1, pushed = 0 })
Assert.is_false(desktop._insight_loaded)
Assert.eq(refreshes, 2)
Assert.eq(rebuilds, 1)

-- 新建桌面不沿用唤醒节流：首次可见必须立即同步书架和统计。
desktop.tab = "home"
source:onEvent("desktop_open", desktop)
Assert.eq(sync_calls, 3)
Assert.eq(stats_calls, 3)
stats_callbacks[3]({ pulled = 1, pushed = 1 })
Assert.eq(refreshes, 3)
Assert.eq(rebuilds, 1)

return true
