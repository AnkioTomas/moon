---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- desktop.sync：桌面可见后台同步、图书馆强制刷新、未配置引导。 --]]

local Assert = require("support.assert")

local followed, rejected = {}, {}
package.preload["workers.ui.task_dialog"] = function()
    return {
        follow = function(task) followed[#followed + 1] = task end,
        rejected = function(reason, task) rejected[#rejected + 1] = { reason = reason, task = task } end,
    }
end
local settings = {}
package.preload["desktop.pages.setting.source"] = function()
    return { loadSetting = function(id) return settings[id] end }
end
local Themed = require("support.theme_stubs")
Themed.install()
local connected = true
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }

local Sync = require("desktop.sync")
local SourceBase = require("source.base")
local Tasks = require("workers.tasks")

local sync_calls, stats_calls, stats_callbacks = 0, 0, {}
local source = setmetatable({
    id = "test",
    name = "Test",
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

local view_updates, refreshes = 0, 0
local desktop = {
    source = source,
    _books_sync = {},
    _stats_sync = {},
    tab = "home",
    updateView = function() view_updates = view_updates + 1 end,
    onEvent = function(self, event, payload)
        Assert.is_true(event ~= "home_refresh", "同步不得整页重建首页")
        if event == "stats_changed" or event == "shelf_changed" then refreshes = refreshes + 1 end
    end,
}

-- 桌面可见：书架与统计都在后台同步，不重建页面。
Sync.open(desktop)
Assert.eq(view_updates, 0)
Assert.is_nil(desktop._books_sync.test)
Assert.eq(sync_calls, 1)
Assert.eq(stats_calls, 1)
Assert.is_true(desktop._stats_sync.test)

-- 统计同步在飞时不得重复发起；书架照常同步。
Sync.open(desktop)
Assert.eq(sync_calls, 2)
Assert.eq(stats_calls, 1)

-- 统计成功落库后，首页必须重新读取本地统计。
stats_callbacks[1]({ pulled = 2, pushed = 1 })
Assert.is_nil(desktop._stats_sync.test)
Assert.eq(refreshes, 1)
Assert.eq(view_updates, 0)

-- 统计 5 分钟节流：刚同步过不再发起。
Sync.open(desktop)
Assert.eq(stats_calls, 1)

-- 手动刷新不受节流；在洞察页时通知统计已变并重绘。
desktop.tab = "insight"
Sync.refresh(desktop)
Assert.eq(stats_calls, 2)
stats_callbacks[2]({ pulled = 1, pushed = 0 })
Assert.eq(refreshes, 2)
Assert.eq(view_updates, 1)
desktop.tab = "home"

-- 统计无新增也无上报：本地数据未变，首页不重建。
Sync.refresh(desktop)
stats_callbacks[3]({ pulled = 0, pushed = 0 })
Assert.eq(refreshes, 2)

-- 以下只看书架：让统计停在飞行中，不再干扰计数。
Sync.refresh(desktop)
Assert.is_true(desktop._stats_sync.test)

-- 书架同步失败：首页展示的是本地数据，不因失败重建。
source.syncBooksAsync = function(_, _, cb)
    cb(nil, "offline")
    return { cancel = function() end }
end
Sync.open(desktop)
Assert.eq(refreshes, 2)

-- 书架同步失败：本地书架不动；后台同步离线不提示，手动刷新才提示。
desktop.tab = "library"
Themed.made = {}
connected = false
local updates_before = view_updates
Sync.open(desktop)
Assert.is_nil(Themed.last("toast"), "后台同步离线失败不打扰")
Assert.eq(view_updates, updates_before, "失败不重建图书馆")
Sync.refresh(desktop)
Assert.eq(Themed.last("toast").text, "offline")
desktop.tab = "home"
connected = true

-- 联网时后台同步失败（如 WebDAV 密码错）：提示一次，同一条错误不再重复；干净成功后再出错重新提示。
do
    local fail = "WebDAV 认证失败：用户名或密码错误"
    local function toasts()
        local n = 0
        for _idx, made in ipairs(Themed.made) do if made.kind == "toast" then n = n + 1 end end
        return n
    end
    source.syncBooksAsync = function(_, _, cb)
        cb(nil, fail)
        return { cancel = function() end }
    end
    Themed.made = {}
    Sync.open(desktop)
    Assert.eq(Themed.last("toast").text, fail)
    Sync.open(desktop)
    Assert.eq(toasts(), 1, "同一条错误只提示一次")
    Sync.refresh(desktop)
    Assert.eq(toasts(), 2, "手动刷新照样提示")

    -- 有本地改动没推上去（push_error）同一规则。
    source.syncBooksAsync = function(_, _, cb)
        cb({ skipped = true, push_error = "WebDAV 没有权限：该账号无法读写这个目录" })
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(Themed.last("toast").text, "WebDAV 没有权限：该账号无法读写这个目录")
    Assert.eq(toasts(), 3)

    source.syncBooksAsync = function(_, _, cb)
        cb({ skipped = true })
        return { cancel = function() end }
    end
    Sync.open(desktop)
    source.syncBooksAsync = function(_, _, cb)
        cb(nil, fail)
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(toasts(), 4, "恢复后再坏要重新提示")
end

-- 书架对账计数全 0：不重建首页。
source.syncBooksAsync = function(_, _, cb)
    cb({ pulled = 0, pushed = 0, hidden = 0 })
    return { cancel = function() end }
end
Sync.open(desktop)
Assert.eq(refreshes, 2)

-- 书架对账有数据：通知首页比对最近书架，由组件决定是否重建。
local last_event
desktop.onEvent = function(_, event) last_event = event end
source.syncBooksAsync = function(_, _, cb)
    cb({ pulled = 467, pushed = 0, hidden = 0 })
    return { cancel = function() end }
end
Sync.open(desktop)
Assert.eq(last_event, "shelf_changed")

-- 手动刷新：进任务队列（sync 类）并前台跟随，源上报的真实步骤进任务快照。
desktop.onEvent = function() end
for i = #followed, 1, -1 do followed[i] = nil end
Assert.eq(#Tasks.tasks(), 0)
local pending, cancels = {}, 0
source.syncBooksAsync = function(_, opts, cb)
    pending[#pending + 1] = { opts = opts, cb = cb }
    return { cancel = function() cancels = cancels + 1 end }
end
Sync.refresh(desktop)
local first = pending[#pending]
Assert.is_true(first.opts.force)
Assert.eq(#Tasks.tasks(), 1)
Assert.eq(Tasks.tasks()[1].kind, "sync")
Assert.len(followed, 1)
Assert.eq(followed[1], Tasks.get("books\0test"))
first.opts.on_progress("正在上传 a.epub", 1, 3)
Assert.eq(Tasks.tasks()[1].text, "正在上传 a.epub")
Assert.eq(Tasks.tasks()[1].count, 1)

-- 刷新中再点：拒绝入队并提示，不取消重来、不叠加、不动在飞状态。
Sync.refresh(desktop)
Assert.len(pending, 1)
Assert.eq(cancels, 0)
Assert.len(followed, 1)
Assert.len(rejected, 1)
Assert.eq(rejected[1].reason, "running")
Assert.eq(rejected[1].task, followed[1])
Assert.is_true(desktop._books_sync.test ~= nil)
first.cb({ skipped = true })
Assert.is_nil(desktop._books_sync.test)
Assert.eq(#Tasks.tasks(), 0)

-- 自动后台同步在飞时手动刷新：取代它；旧请求迟到的进度与结果丢弃。
Sync.open(desktop)
local auto = pending[#pending]
Assert.is_nil(auto.opts.force)
Sync.refresh(desktop)
Assert.eq(cancels, 1)
local forced = pending[#pending]
Assert.is_true(forced.opts.force)
auto.opts.on_progress("旧请求", 2, 3)
auto.cb({ skipped = true })
Assert.is_true(desktop._books_sync.test ~= nil, "旧请求结果不落地")
Assert.is_nil(Tasks.tasks()[1].text)
forced.cb({ skipped = true })
Assert.is_nil(desktop._books_sync.test)
Assert.eq(#Tasks.tasks(), 0)

-- 换源后旧源的结果不落到新源的页面上。
local other = setmetatable({ id = "other", configured = function() return true end }, { __index = SourceBase })
Sync.open(desktop)
local stale = pending[#pending]
desktop.source = other
local stale_events = 0
desktop.onEvent = function() stale_events = stale_events + 1 end
stale.cb({ pulled = 1, pushed = 0, hidden = 0 })
Assert.is_nil(desktop._books_sync.test)
Assert.eq(stale_events, 0)
desktop.source = source

-- 未配置：后台打开静默跳过；手动刷新说明原因，源有设置入口就给直达按钮。
local calls_before = #pending
source.configured = function() return false end
Sync.open(desktop)
Assert.eq(#pending, calls_before)
Assert.is_nil(Themed.last("confirm"))

local opened_with
settings.test = { open = function(plugin) opened_with = plugin end }
desktop.plugin = {}
Sync.refresh(desktop)
Assert.eq(#pending, calls_before)
local confirm = Themed.last("confirm")
Assert.eq(confirm.text, "请先完成数据源设置，再刷新书库。")
Assert.eq(confirm.ok_text, "立即设置")
confirm.ok_callback()
Assert.eq(opened_with, desktop.plugin)

-- 源没有设置入口：只提示，不给按钮。
settings.test = nil
Sync.refresh(desktop)
Assert.eq(Themed.last("toast").text, "请先完成数据源设置，再刷新书库。")

-- 混合模式（#42）：活跃源是本地书籍时，其它已启用、已登录源的远端书架也要同步；未配置的跳过不提示。
do
    local Registry = require("source.registry")
    local MoonSettings = require("utils.settings")
    local saved = { listEnabled = Registry.listEnabled, resolve = Registry.resolve, isEnabled = Registry.isEnabled }
    local was_mixed = MoonSettings.get("source").library_mixed
    MoonSettings.get("source").library_mixed = true

    local synced, holds = {}, {}
    local function mk(id, configured)
        return setmetatable({
            id = id, name = id,
            configured = function() return configured end,
            syncBooksAsync = function(_, opts, cb)
                synced[#synced + 1] = id .. (opts.force and ":force" or "")
                holds[id] = cb
                return { cancel = function() end }
            end,
        }, { __index = SourceBase })
    end
    local pool = { ["local"] = mk("local", true), wechat = mk("wechat", true), moon = mk("moon", false) }
    local enabled = { ["local"] = true, wechat = true, moon = true }
    Registry.listEnabled = function() return { { id = "local" }, { id = "moon" }, { id = "wechat" } } end
    Registry.resolve = function(id) return pool[id] end
    Registry.isEnabled = function(id) return enabled[id] == true end

    local mixed_events = 0
    local desk = {
        source = pool["local"], tab = "home", _books_sync = {}, _stats_sync = {},
        updateView = function() end,
        onEvent = function(_, event) if event == "shelf_changed" then mixed_events = mixed_events + 1 end end,
    }
    Sync.open(desk)
    Assert.eq(table.concat(synced, ","), "local,wechat", "未配置的月读服务跳过")

    -- 两个源同时在飞，各自的结果互不顶替。
    holds.wechat({ pulled = 5, pushed = 0, hidden = 0 })
    holds["local"]({ pulled = 1, pushed = 0, hidden = 0 })
    Assert.eq(mixed_events, 2)
    Assert.is_nil(desk._books_sync.wechat)

    -- 停用的源迟到的结果不落到页面上。
    Sync.open(desk)
    enabled.wechat = false
    holds.wechat({ pulled = 5, pushed = 0, hidden = 0 })
    Assert.eq(mixed_events, 2)
    holds["local"]({ skipped = true })
    enabled.wechat = true

    -- 手动刷新：多个源一起入队，不逐个弹进度窗，只提示一次。
    for i = #followed, 1, -1 do followed[i] = nil end
    synced = {}
    Sync.refresh(desk)
    Assert.eq(table.concat(synced, ","), "local:force,wechat:force")
    Assert.len(followed, 0)
    Assert.eq(Themed.last("toast").text, "正在同步 2 个数据源，可在顶栏查看进度")
    holds["local"]({ skipped = true })
    holds.wechat({ skipped = true })

    -- 活跃源未配置也不拦手动刷新：混合模式只刷已配置的。
    desk.source = pool.moon
    synced = {}
    Sync.refresh(desk)
    Assert.eq(table.concat(synced, ","), "local:force,wechat:force")
    holds["local"]({ skipped = true })
    holds.wechat({ skipped = true })

    -- 混合模式打开桌面的书架后台同步有节流：刚同步过（含手动刷新）不再发起。
    synced = {}
    Sync.open(desk)
    Assert.eq(#synced, 0, "混合模式书架后台同步节流")

    -- 一个已配置的源都没有：手动刷新要说明原因。
    pool["local"].configured = function() return false end
    pool.wechat.configured = function() return false end
    Themed.last("toast").text = nil
    Sync.refresh(desk)
    Assert.eq(#synced, 0)
    Assert.eq(Themed.last("toast").text, "请先完成数据源设置，再刷新书库。")

    for k, fn in pairs(saved) do Registry[k] = fn end
    MoonSettings.get("source").library_mixed = was_mixed
end

return true
