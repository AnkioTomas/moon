--[[-- Deferred statistics work must be invalidated when its source changes. --]]

local Assert = require("support.assert")

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function() return "test-device" end,
    saveSetting = function() end,
}

package.preload["device"] = function() return { model = "Test" } end
package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
local pending_rows = {
    { id = 1, stable_id = "a.epub", page = 1, start_time = 1000, duration = 30, total_pages = 300 },
}
package.preload["utils.db.stats"] = function()
    return {
        countBySource = function()
            return #pending_rows
        end,
        allBySource = function()
            return pending_rows
        end,
        deleteIds = function()
            return true
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker)
            worker()
        end,
    }
end
package.loaded["device"] = nil
package.loaded["ui/widget/infomessage"] = nil
package.loaded["ui/network/manager"] = nil
package.loaded["utils.db.stats"] = nil
package.loaded["utils.db.queue"] = nil
package.loaded["stats.stats_sync"] = nil

local StatsSync = require("stats.stats_sync")
local register_callback
local cancelled = false
local api = {
    id = "moon",
    configured = function()
        return true
    end,
    registerReadingDeviceAsync = function(_, _, _, cb)
        register_callback = cb
        return { cancel = function() cancelled = true end }
    end,
    importReadingStatsAsync = function()
        error("invalidated job must not upload")
    end,
}

local done_ok, done_err
Assert.is_true(StatsSync.pushAsync(api, {
    force = true,
    on_done = function(ok, err)
        done_ok, done_err = ok, err
    end,
}))
StatsSync.invalidate()
Assert.is_true(cancelled)
Assert.eq(done_ok, false)
Assert.eq(done_err, "cancelled")

register_callback(true)
Assert.is_true(not StatsSync.isBusy())

-- 无本地统计：快速失败，不打扰网络
pending_rows = {}
local empty_ok, empty_err = StatsSync.pushAsync(api, { force = true })
Assert.is_true(not empty_ok)
Assert.eq(empty_err, "无阅读统计数据")

_G.G_reader_settings = previous_settings
for _, name in ipairs({
    "device",
    "ui/widget/infomessage",
    "ui/network/manager",
    "libs/libkoreader-lfs",
    "utils.paths",
    "utils.db.stats",
    "utils.db.queue",
    "stats.stats_sync",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
