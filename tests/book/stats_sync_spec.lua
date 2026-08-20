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
local delete_ok = true
package.preload["utils.db.stats"] = function()
    return {
        countBySource = function()
            return #pending_rows
        end,
        allBySource = function()
            return pending_rows
        end,
        deleteIds = function()
            if delete_ok then deleted = true end
            return delete_ok
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            local ok, err = pcall(worker)
            local cb = ok and opts and opts.on_done or opts and opts.on_failed
            if cb then cb(ok and nil or err) end
        end,
    }
end
package.loaded["ui/widget/infomessage"] = nil
package.loaded["ui/network/manager"] = nil
package.loaded["utils.db.stats"] = nil
package.loaded["utils.db.queue"] = nil
package.loaded["book.stats"] = nil
package.loaded["book.stats_sync"] = nil

local StatsSync = require("book.stats")
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

-- 服务端确认且本地对应 ID 删除完成，才算上报成功。
local success_ok
Assert.is_true(StatsSync.pushAsync(api, {
    force = true,
    on_done = function(ok) success_ok = ok end,
}))
import_callback({ ok = true })
Assert.is_true(success_ok)
Assert.is_true(deleted)

-- 本地确认删除失败时保留记录，并把本次上报标成失败。
deleted = false
delete_ok = false
pending_rows = {
    { id = 2, stable_id = "b.epub", page = 2, start_time = 2000, duration = 20, total_pages = 200 },
}
local delete_done, delete_err
Assert.is_true(StatsSync.pushAsync(api, {
    force = true,
    on_done = function(ok, err)
        delete_done, delete_err = ok, err
    end,
}))
import_callback({ ok = true })
Assert.is_false(delete_done)
Assert.not_nil(delete_err)
Assert.is_false(deleted)
delete_ok = true

-- 无本地统计：快速失败，不打扰网络
pending_rows = {}
local empty_ok, empty_err = StatsSync.pushAsync(api, { force = true })
Assert.is_true(empty_ok)
Assert.eq(empty_err, "empty")

_G.G_reader_settings = previous_settings
for _, name in ipairs({
    "ui/widget/infomessage",
    "ui/network/manager",
    "libs/libkoreader-lfs",
    "utils.paths",
    "utils.db.stats",
    "utils.db.queue",
    "book.stats", "book.stats_sync",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
