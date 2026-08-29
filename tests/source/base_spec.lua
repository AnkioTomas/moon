--[[-- source.base：首页同步在后台进行，不阻塞本地首页数据。 --]]

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
    rebuild = function() rebuilds = rebuilds + 1 end,
    -- 真实实现是 Home.invalidate：清状态后仅在首页时重建
    invalidateHome = function(self)
        self._home_state = nil
        self._home_loaded = false
        if self.tab == "home" then rebuilds = rebuilds + 1 end
    end,
}
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 0)
Assert.is_false(desktop._books_sync_pending)

-- 重复的跳过结果仍保持零重建。
source:onEvent("home_open", desktop)
Assert.eq(rebuilds, 0)

return true
