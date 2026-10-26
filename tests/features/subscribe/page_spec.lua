--[[-- features.subscribe.page：切到订阅页时自动刷新过期源（与图书馆后台同步同周期 Subscribe.STALE，进程内节流，离线不刷）。 --]]

local Assert = require("support.assert")
require("support.stubs").install()

local now = os.time()
local feeds = {
    { id = 1, title = "刚刷过", updated_at = now },
    { id = 2, title = "过期", updated_at = now - 301 },
    { id = 3, title = "从没刷过", updated_at = 0 },
}
local connected = true
local starts = {}
package.loaded["features.subscribe"] = { STALE = 5 * 60 }
package.loaded["features.subscribe.db"] = {
    feeds = function() return feeds end,
    feed = function() return nil end,
}
package.loaded["features.subscribe.refresh"] = {
    start = function(list, opts) starts[#starts + 1] = { list = list, opts = opts } return true end,
    watch = function() return function() end end,
    status = function() return nil end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui/widget/horizontalgroup"] = {}
package.loaded["ui/widget/horizontalspan"] = {}
package.loaded["ui.themes"] = {}
package.loaded["ui.themes.widgets.box"] = {}
package.loaded["ui.themes.widgets.button"] = {}
package.loaded["ui.input"] = {}
package.loaded["features.subscribe.page"] = nil
local Page = require("features.subscribe.page")

-- 全部新鲜：不刷，也不占节流
feeds = { { id = 1, title = "刚刷过", updated_at = now } }
Page:activate()
Assert.len(starts, 0)

-- 离线：不刷，也不占节流
feeds[2] = { id = 2, title = "过期", updated_at = now - 301 }
feeds[3] = { id = 3, title = "从没刷过", updated_at = 0 }
connected = false
Page:activate()
Assert.len(starts, 0, "离线不自动刷新")

-- 联网：只刷过期与从没刷过的，静默（quiet）；刚刷过的不动
connected = true
Page:activate()
Assert.len(starts, 1)
local ids = {}
for _idx, feed in ipairs(starts[1].list) do ids[#ids + 1] = feed.id end
Assert.eq(table.concat(ids, ","), "2,3")
Assert.is_true(starts[1].opts.quiet)

-- 周期内再激活：节流，不重复刷（与图书馆后台同步一致）
Page:activate()
Assert.len(starts, 1, "5 分钟内不重复自动刷新")
