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
package.loaded["device"] = nil
package.loaded["ui/widget/infomessage"] = nil
package.loaded["ui/network/manager"] = nil
package.loaded["stats.stats_sync"] = nil

local StatsSync = require("stats.stats_sync")
local register_callback
local cancelled = false
local api = {
    id = "moon",
    capabilities = function()
        return { stats_import = true }
    end,
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

_G.G_reader_settings = previous_settings
for _, name in ipairs({
    "device",
    "ui/widget/infomessage",
    "ui/network/manager",
    "libs/libkoreader-lfs",
    "utils.paths",
    "stats.stats_sync",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
