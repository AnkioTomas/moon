--[[-- source.base：首页等待书架同步的事件契约。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local SourceBase = require("source.base")
local source = setmetatable({
    id = "test",
    configured = function() return true end,
    syncBooksAsync = function(_, _, cb)
        cb({ skipped = true })
        return { cancel = function() end }
    end,
}, { __index = SourceBase })

local rebuilds = 0
local desktop = {
    source = source,
    tab = "home",
    _home_waiting_sync = true,
    rebuild = function() rebuilds = rebuilds + 1 end,
    -- 真实实现是 Home.invalidate：清状态后仅在首页时重建
    invalidateHome = function(self)
        self._home_state = nil
        self._home_loaded = false
        if self.tab == "home" then rebuilds = rebuilds + 1 end
    end,
}
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 1)
Assert.is_false(desktop._books_sync_pending)
Assert.is_nil(desktop._home_waiting_sync)

-- 非等待状态的节流命中仍保持零重建。
desktop._home_waiting_sync = nil
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 1)

return true
