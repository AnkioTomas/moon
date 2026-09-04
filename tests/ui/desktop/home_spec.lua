--[[--
首页加载状态：书架同步在飞时也先读本地数据，完成后再刷新。

@module tests.ui.desktop.home_spec
--]]

local Assert = require("support.assert")

local ticks = {}
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn)
            ticks[#ticks + 1] = fn
        end,
        scheduleIn = function(_, _, fn)
            ticks[#ticks + 1] = fn
        end,
        unschedule = function(_, fn)
            for i = #ticks, 1, -1 do
                if ticks[i] == fn then table.remove(ticks, i) end
            end
        end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255 }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end } }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
local function widget()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/container/framecontainer"] = widget
package.preload["ui/widget/textwidget"] = widget
package.preload["ui.components.bookinfo"] = function()
    return { file = function(book) return book and book.stable_id end }
end
package.preload["ui.components.bookui"] = function()
    return { face = function() return {} end, muted = function() return 0 end }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end
package.preload["ui.desktop.home.stats"] = function()
    return { summarize = function() return {} end }
end
package.preload["book.highlights"] = function()
    return { pick = function() end, collect = function() return {} end }
end
package.preload["ui.desktop.home.layout"] = function()
    return { build = function(_, state) return { state = state } end }
end
package.preload["logger"] = function()
    return { err = function() end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end

local Home = require("ui.desktop.home")
local calls = 0
local desktop = {
    tab = "home",
    _books_sync_pending = true,
    _local_cleanup_done = true,
    source_generation = 0,
    source = {
        id = "local",
        recentBooksAsync = function(_, _, cb)
            calls = calls + 1
            cb({ data = { { stable_id = "book-1" } } })
            return { cancel = function() end }
        end,
    },
    contentHeight = function() return 400 end,
    ctx = function(self) return { desktop = self } end,
    rebuild = function(self) self.rebuilds = (self.rebuilds or 0) + 1 end,
}

-- 首屏不等待网络同步，直接读取本地最近阅读。
Home.page(desktop)
Assert.is_false(desktop._home_loaded and true or false)
Assert.eq(#ticks, 1)
ticks[1]()
Assert.is_true(desktop._home_loaded)
Assert.eq(calls, 1)
Assert.eq(desktop._home_state.recent.stable_id, "book-1")

-- cancel 只是尽力而为：同源旧请求的晚到回调不得覆盖新一轮状态。
local callbacks = {}
desktop.source.recentBooksAsync = function(_, _, cb)
    callbacks[#callbacks + 1] = cb
    return { cancel = function() end }
end
Home.invalidate(desktop)
ticks[#ticks]()
local first = callbacks[#callbacks]
Home.invalidate(desktop)
ticks[#ticks]()
local second = callbacks[#callbacks]
second({ data = { { stable_id = "new" } } })
first({ data = { { stable_id = "old" } } })
Assert.eq(desktop._home_state.recent.stable_id, "new")

-- 后台更新保留旧内容；200ms 内重复通知合并，取数完成后只重建一次。
ticks = {}
desktop._home_loaded = true
desktop._home_state = { recent = { stable_id = "visible" } }
desktop.source.recentBooksAsync = function(_, _, cb)
    calls = calls + 1
    cb({ data = { { stable_id = "refreshed" } } })
    return { cancel = function() end }
end
local before_refresh = desktop.rebuilds or 0
Home.refreshData(desktop)
Home.refreshData(desktop)
Assert.eq(#ticks, 1)
Assert.eq(desktop._home_state.recent.stable_id, "visible")
ticks[1]()
Assert.eq(desktop.rebuilds, before_refresh + 1)
Assert.eq(calls, 2)

-- 进入首页统一入口：清状态 + 重建 + 通知源，下一次 page 必然重拉。
local emitted
desktop.plugin = {
    emitToSource = function(_, event) emitted = event end,
}
desktop.scheduleClockTick = function() end
local before = desktop.rebuilds or 0
Home.refreshOnEnter(desktop)
Assert.is_false(desktop._home_loaded)
Assert.is_nil(desktop._home_state)
Assert.eq(desktop.rebuilds, before + 1)
Assert.eq(emitted, "home_open")

-- 不在首页时只作废状态，不重建（避免在设置页乱刷屏）。
desktop.tab = "settings"
desktop._home_loaded = true
Home.invalidate(desktop)
Assert.is_false(desktop._home_loaded)
Assert.eq(desktop.rebuilds, before + 1)

return true
