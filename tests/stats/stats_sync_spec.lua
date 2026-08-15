--[[-- Deferred statistics work must be invalidated when its source changes. --]]

local Assert = require("support.assert")

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function() return "test-device" end,
    saveSetting = function() end,
}

package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
local pending_rows = {
    { id = 1, stable_id = "a.epub", page = 1, start_time = 1000, duration = 30, total_pages = 300 },
}
local deleted = false
package.preload["utils.db.stats"] = function()
    return {
        countBySource = function()
            return #pending_rows
        end,
        allBySource = function()
            return pending_rows
        end,
        deleteIds = function()
            deleted = true
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
package.loaded["ui/widget/infomessage"] = nil
package.loaded["ui/network/manager"] = nil
package.loaded["utils.db.stats"] = nil
package.loaded["utils.db.queue"] = nil
package.loaded["stats.stats_sync"] = nil

local StatsSync = require("stats.stats_sync")
local import_callback
local cancelled = false
local api = {
    id = "moon",
    configured = function()
        return true
    end,
    importReadingStatsAsync = function(_, _payload, cb)
        import_callback = cb
        return { cancel = function() cancelled = true end }
    end,
}

local done_ok, done_err
Assert.is_true(StatsSync.pushAsync(api, {
    force = true,
    on_done = function(ok, err)
        done_ok, done_err = ok, err
    end,
}))
Assert.is_true(import_callback ~= nil) -- 上传任务已挂起
StatsSync.invalidate()
Assert.is_true(cancelled)
Assert.eq(done_ok, false)
Assert.eq(done_err, "cancelled")

-- 失效后迟到回调不得收尾、不得删本地记录
import_callback({ ok = true })
Assert.is_true(not StatsSync.isBusy())
Assert.is_true(not deleted)

-- 无本地统计：快速失败，不打扰网络
pending_rows = {}
local empty_ok, empty_err = StatsSync.pushAsync(api, { force = true })
Assert.is_true(not empty_ok)
Assert.eq(empty_err, "无阅读统计数据")

_G.G_reader_settings = previous_settings
for _, name in ipairs({
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
