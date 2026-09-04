--[[-- source.base：首页同步在后台进行，不阻塞本地首页数据。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local stats_callbacks = {}
package.preload["book.stats"] = function()
    return {
        pullInBackground = function(_, opts)
            stats_callbacks[#stats_callbacks + 1] = opts.on_done
        end,
    }
end

local SourceBase = require("source.base")
local sync_calls = 0
local source = setmetatable({
    id = "test",
    configured = function() return true end,
    syncBooksAsync = function(_, _, cb)
        sync_calls = sync_calls + 1
        cb({ skipped = true })
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
Assert.len(stats_callbacks, 1)

-- 重复的跳过结果仍保持零重建。
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 0)
Assert.eq(sync_calls, 2)

-- 统计成功落库后，首页必须重新读取本地统计。
stats_callbacks[2](true)
Assert.eq(refreshes, 1)
Assert.eq(rebuilds, 0)

-- 唤醒事件受书架节流约束，但统计拉取由统计模块自己的节流负责。
source._books_refresh_at = os.time()
desktop.tab = "stats"
source:onEvent("desktop_resume", desktop)
Assert.eq(sync_calls, 2)
Assert.len(stats_callbacks, 3)
stats_callbacks[3](true)
Assert.is_false(desktop._insight_loaded)
Assert.eq(refreshes, 2)
Assert.eq(rebuilds, 1)

-- 新建桌面不沿用唤醒节流：首次可见必须立即同步书架和统计。
desktop.tab = "home"
source:onEvent("desktop_open", desktop)
Assert.eq(sync_calls, 3)
Assert.len(stats_callbacks, 4)
stats_callbacks[4](true)
Assert.eq(refreshes, 3)
Assert.eq(rebuilds, 1)

return true
