---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- desktop.sync：桌面可见后台同步、图书馆手动刷新（单击增量、长按全量）、未配置引导。 --]]

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

-- 后台补全写库后由 desktop 统一发 shelf_changed；桌面已关（人在阅读器里）不通知。
do
    local seen_opts, events = nil, 0
    local original_on_event = desktop.onEvent
    desktop.onEvent = function(_, event) if event == "shelf_changed" then events = events + 1 end end
    source.syncBooksAsync = function(_, opts, cb)
        seen_opts = opts
        cb({ skipped = false, pulled = 0, pushed = 0, hidden = 0 })
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(type(seen_opts.on_changed), "function", "同步把 on_changed 传给源")
    seen_opts.on_changed()
    Assert.eq(events, 1, "补全写库后首页重读")
    desktop.closed = true
    seen_opts.on_changed()
    Assert.eq(events, 1, "桌面已关不通知")
    desktop.closed = nil
    desktop.onEvent = original_on_event
end

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

-- 唤醒半联网：isConnected 为真但本机路由还不通，后台不弹 LuaSocket 原文；手动刷新仍提示。
do
    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        cb(nil, "无法连接 WebDAV 服务器：Could not connect: Network is unreachable")
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.is_nil(Themed.last("toast"), "唤醒半联网后台不打扰")
    Sync.refresh(desktop)
    Assert.eq(Themed.last("toast").text,
        "无法连接 WebDAV 服务器：Could not connect: Network is unreachable")
end

-- 唤醒半联网：connection refused（大小写不敏感）后台不弹；手动刷新仍提示。
do
    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        cb(nil, "Could not connect: connection refused")
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.is_nil(Themed.last("toast"), "connection refused 后台不打扰")
    Sync.refresh(desktop)
    Assert.eq(Themed.last("toast").text, "Could not connect: connection refused")

    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        cb(nil, "Could not connect: Connection refused")
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.is_nil(Themed.last("toast"), "Connection refused 后台不打扰")
    Sync.refresh(desktop)
    Assert.eq(Themed.last("toast").text, "Could not connect: Connection refused")
end

-- Turbo 连接失败不一定带可识别的原因；后台拉取 / 推送都静默，手动刷新保留错误。
do
    for _idx, err in ipairs({
        "Could not connect",
        "Could not connect: -1",
        "Could not connect: timeout",
        "无法连接 WebDAV 服务器：Could not connect: socket closed",
        "COULD NOT CONNECT: unknown",
    }) do
        for _mode, pushing in ipairs({ false, true }) do
            Themed.made = {}
            source.syncBooksAsync = function(_, _, cb)
                if pushing then
                    cb({ skipped = true, push_error = err })
                else
                    cb(nil, err)
                end
                return { cancel = function() end }
            end
            local before = view_updates
            Sync.open(desktop)
            Assert.is_nil(Themed.last("toast"), "后台连接失败不打扰：" .. err)
            Assert.eq(view_updates, before, "连接失败不重建本地书架")
            Sync.refresh(desktop)
            Assert.eq(Themed.last("toast").text, err, "手动刷新保留连接错误")
        end
    end
end

-- 半联网后台失败后延迟重试：成功不弹；仍失败保持静默；不叠加、不无限重试；关桌面取消。
do
    local UIManager = require("ui/uimanager")
    local pending = {}
    local orig_in, orig_un = UIManager.scheduleIn, UIManager.unschedule
    function UIManager:scheduleIn(delay, fn)
        pending[#pending + 1] = { delay = delay, fn = fn }
    end
    function UIManager:unschedule(fn)
        for i = #pending, 1, -1 do
            if pending[i].fn == fn then table.remove(pending, i) end
        end
    end
    local function fire()
        Assert.is_true(#pending > 0, "应已安排重试")
        local item = table.remove(pending, 1)
        item.fn()
        return item.delay
    end

    local calls = 0
    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        calls = calls + 1
        if calls == 1 then
            cb(nil, "Could not connect: -1")
        else
            cb({ skipped = true })
        end
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(calls, 1)
    Assert.is_nil(Themed.last("toast"), "首次半联网后台不打扰")
    Assert.eq(#pending, 1)
    Assert.eq(fire(), 3)
    Assert.eq(calls, 2, "约 3s 后重试")
    Assert.is_nil(Themed.last("toast"), "重试成功不提示")
    Assert.eq(#pending, 0, "成功后不再预约")

    calls = 0
    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        calls = calls + 1
        cb(nil, "Could not connect")
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(calls, 1)
    Assert.is_nil(Themed.last("toast"))
    Assert.eq(fire(), 3)
    Assert.eq(calls, 2, "约 3s 再试")
    Assert.is_nil(Themed.last("toast"), "重试仍半联网不打扰")
    Assert.eq(fire(), 8)
    Assert.eq(calls, 3, "约 8s 再试")
    Assert.is_nil(Themed.last("toast"))
    Assert.eq(#pending, 0, "不再无限重试")

    Sync.open(desktop)
    Assert.eq(calls, 4)
    Assert.eq(#pending, 1)
    Sync.open(desktop)
    Assert.eq(calls, 5)
    Assert.eq(#pending, 1, "再次打开桌面不叠加重试")
    Assert.eq(pending[1].delay, 3, "新一轮从 3s 重计")

    desktop.closed = true
    fire()
    Assert.eq(calls, 5, "桌面已关不再重试")
    desktop.closed = nil
    Assert.eq(#pending, 0)

    Sync.open(desktop)
    Assert.eq(#pending, 1)
    Sync.onClose(desktop)
    Assert.eq(#pending, 0, "关桌面取消待重试")

    calls = 0
    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        calls = calls + 1
        if calls == 1 then
            cb(nil, "Could not connect: connection refused")
        else
            cb({ skipped = true })
        end
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(calls, 1)
    Assert.eq(#pending, 1)
    Sync.onNetworkConnected(desktop)
    Assert.eq(calls, 2, "NetworkConnected 立刻再同步")
    Assert.eq(#pending, 0)
    Assert.is_nil(Themed.last("toast"), "网络恢复后成功不提示")

    -- 混合模式：半联网失败清掉节流，延迟重试才会再同步。
    local Registry = require("source.registry")
    local MoonSettings = require("utils.settings")
    local saved = { listEnabled = Registry.listEnabled, resolve = Registry.resolve, isEnabled = Registry.isEnabled }
    local was_mixed = MoonSettings.get("source").library_mixed
    MoonSettings.get("source").library_mixed = true
    local mixed_src = setmetatable({
        id = "netdown", name = "netdown",
        configured = function() return true end,
        syncBooksAsync = function() end,
    }, { __index = SourceBase })
    local mixed_calls = 0
    mixed_src.syncBooksAsync = function(_, _, cb)
        mixed_calls = mixed_calls + 1
        if mixed_calls == 1 then
            cb(nil, "Could not connect: connection refused")
        else
            cb({ skipped = true })
        end
        return { cancel = function() end }
    end
    Registry.listEnabled = function() return { { id = "netdown" } } end
    Registry.resolve = function(id) return id == "netdown" and mixed_src or nil end
    Registry.isEnabled = function(id) return id == "netdown" end
    local desk = {
        source = mixed_src, tab = "home", _books_sync = {}, _stats_sync = {},
        updateView = function() end, onEvent = function() end,
    }
    Themed.made = {}
    Sync.open(desk)
    Assert.eq(mixed_calls, 1)
    Assert.is_nil(Themed.last("toast"))
    -- 若未清节流，3s 后的 Sync.open 会被 5 分钟窗口跳过。
    Assert.eq(fire(), 3)
    Assert.eq(mixed_calls, 2, "半联网失败不清节流则重试发不出去")
    Assert.is_nil(Themed.last("toast"), "混合模式重试成功不提示")
    for k, fn in pairs(saved) do Registry[k] = fn end
    MoonSettings.get("source").library_mixed = was_mixed

    UIManager.scheduleIn, UIManager.unschedule = orig_in, orig_un
end

-- 不带 Could not connect 的对端超时保留原有提示。
do
    Themed.made = {}
    source.syncBooksAsync = function(_, _, cb)
        cb(nil, "Connection timed out")
        return { cancel = function() end }
    end
    Sync.open(desktop)
    Assert.eq(Themed.last("toast").text, "Connection timed out")
end

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
Assert.is_nil(first.opts.force, "单击走增量")
Assert.is_true(first.opts.manual)
Assert.eq(Tasks.tasks()[1].title, "Test · 增量刷新")
Assert.eq(#Tasks.tasks(), 1)
Assert.eq(Tasks.tasks()[1].kind, "sync")
Assert.len(followed, 1)
Assert.eq(followed[1], Tasks.get("books\0test"))
first.opts.on_progress("正在上传 a.epub", 1, 3)
Assert.eq(Tasks.tasks()[1].text, "正在上传 a.epub")
Assert.eq(Tasks.tasks()[1].count, 1)

-- 刷新中再点（含改成长按全量）：拒绝入队并提示，不取消重来、不叠加、不动在飞状态。
Sync.refresh(desktop)
Sync.refresh(desktop, true)
Assert.len(pending, 1)
Assert.eq(cancels, 0)
Assert.len(followed, 1)
Assert.len(rejected, 2)
Assert.eq(rejected[1].reason, "running")
Assert.eq(rejected[1].task, followed[1])
Assert.eq(rejected[2].reason, "running")
Assert.is_true(desktop._books_sync.test ~= nil)
first.cb({ skipped = true })
Assert.is_nil(desktop._books_sync.test)
Assert.eq(#Tasks.tasks(), 0)

-- 自动后台同步在飞时手动刷新（增量或全量）都取代它；旧请求迟到的进度与结果丢弃。
Sync.open(desktop)
local auto = pending[#pending]
Assert.is_nil(auto.opts.force)
Assert.is_nil(auto.opts.manual)
Sync.refresh(desktop)
Assert.eq(cancels, 1)
local incremental = pending[#pending]
Assert.is_nil(incremental.opts.force)
Assert.is_true(incremental.opts.manual)
auto.opts.on_progress("旧请求", 2, 3)
auto.cb({ skipped = true })
Assert.is_true(desktop._books_sync.test ~= nil, "旧请求结果不落地")
Assert.is_nil(Tasks.tasks()[1].text)
incremental.cb({ skipped = true })
Assert.is_nil(desktop._books_sync.test)
Assert.eq(#Tasks.tasks(), 0)

Sync.open(desktop)
auto = pending[#pending]
Sync.refresh(desktop, true)
Assert.eq(cancels, 2)
local forced = pending[#pending]
Assert.is_true(forced.opts.force)
Assert.is_true(forced.opts.manual)
Assert.eq(Tasks.tasks()[1].title, "Test · 全量刷新")
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

-- 未配置：后台打开静默跳过；手动刷新打开对应源账号页。
local calls_before = #pending
source.configured = function() return false end
Sync.open(desktop)
Assert.eq(#pending, calls_before)
Assert.is_nil(Themed.last("confirm"))

local opened = {}
package.loaded["desktop.pages.setting.source"] = {
    loadSetting = function(id) return settings[id] end,
    openAccount = function(desk, id)
        opened[#opened + 1] = { desk = desk, id = id }
    end,
}
desktop.plugin = {}
Sync.refresh(desktop)
Assert.eq(#pending, calls_before)
local confirm = Themed.last("confirm")
Assert.eq(confirm.text, "请先完成数据源设置，再刷新书库。")
Assert.eq(confirm.ok_text, "去登录")
confirm.ok_callback()
Assert.eq(opened[1].desk, desktop)
Assert.eq(opened[1].id, source.id)

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

    -- 手动增量刷新：多个源一起入队，不逐个弹进度窗，只提示一次。
    for i = #followed, 1, -1 do followed[i] = nil end
    synced = {}
    Sync.refresh(desk)
    Assert.eq(table.concat(synced, ","), "local,wechat")
    Assert.len(followed, 0)
    Assert.eq(Themed.last("toast").text, "正在增量同步 2 个数据源，可在顶栏查看进度")
    holds["local"]({ skipped = true })
    holds.wechat({ skipped = true })

    -- 长按全量：同样只提示一次，并带全量标志。
    Themed.made = {}
    synced = {}
    Sync.refresh(desk, true)
    Assert.eq(table.concat(synced, ","), "local:force,wechat:force")
    Assert.len(followed, 0)
    Assert.eq(Themed.last("toast").text, "正在全量同步 2 个数据源，可在顶栏查看进度")
    holds["local"]({ skipped = true })
    holds.wechat({ skipped = true })

    -- 活跃源未配置也不拦手动刷新：混合模式只刷已配置的。
    desk.source = pool.moon
    synced = {}
    Sync.refresh(desk)
    Assert.eq(table.concat(synced, ","), "local,wechat")
    holds["local"]({ skipped = true })
    holds.wechat({ skipped = true })

    -- 混合模式打开桌面的书架后台同步有节流：刚同步过（含手动刷新）不再发起。
    synced = {}
    Sync.open(desk)
    Assert.eq(#synced, 0, "混合模式书架后台同步节流")

    -- 一个已配置的源都没有：手动刷新打开账号页，不要只 toast。
    pool["local"].configured = function() return false end
    pool.wechat.configured = function() return false end
    Themed.made = {}
    local opened_mixed = {}
    package.loaded["desktop.pages.setting.source"] = {
        openAccount = function(d, id) opened_mixed[#opened_mixed + 1] = { desk = d, id = id } end,
    }
    Sync.refresh(desk)
    Assert.eq(#synced, 0)
    local mixed_confirm = Themed.last("confirm")
    Assert.eq(mixed_confirm.text, "请先完成数据源设置，再刷新书库。")
    Assert.eq(mixed_confirm.ok_text, "去登录")
    mixed_confirm.ok_callback()
    Assert.eq(opened_mixed[1].desk, desk)
    Assert.is_nil(opened_mixed[1].id)

    for k, fn in pairs(saved) do Registry[k] = fn end
    MoonSettings.get("source").library_mixed = was_mixed
end

-- 登录失效弹窗：永远中文模板；接口原文（NOT.LOGIN）不进正文；中文说明才附上；重新登录进账号页。
do
    local Stubs = require("support.stubs")
    local Registry = require("source.registry")
    local saved_meta = Registry.meta
    Registry.meta = function(id)
        return { name = id == "jdread" and "京东读书" or id }
    end
    local opened = {}
    package.loaded["desktop.pages.setting.source"] = {
        openAccount = function(desk, id) opened[#opened + 1] = { desk = desk, id = id } end,
    }

    Themed.made = {}
    Sync.promptLogin({ desktop = desktop }, "jdread", "NOT.LOGIN")
    Stubs.flush()
    local box = Themed.last("text_viewer")
    Assert.not_nil(box)
    Assert.matches(box.text, "京东读书%s+登录已失效")
    Assert.is_true(not tostring(box.text):find("NOT.LOGIN", 1, true))
    Assert.eq(box.buttons[2].text, "重新登录")
    box.buttons[2].callback()
    Assert.is_true(box.closed)
    Assert.eq(opened[1].id, "jdread")
    Assert.eq(opened[1].desk, desktop)

    Themed.made = {}
    Sync.promptLogin({ desktop = desktop }, "jdread",
        "京东读书登录已失效，请重新扫码登录")
    Stubs.flush()
    box = Themed.last("text_viewer")
    Assert.matches(box.text, "请重新扫码登录")
    box.buttons[1].callback()
    Assert.is_true(box.closed)
    Assert.len(opened, 1, "稍后只关窗，不打开账号页")

    Registry.meta = saved_meta
end

-- 本地文件变了（远程上传）：只重扫本地书籍源，别的源不动
do
    local scanned = {}
    local function fake(id)
        return setmetatable({
            id = id, name = id, configured = function() return true end,
            syncBooksAsync = function(_, opts, cb)
                scanned[#scanned + 1] = id .. (opts.force and ":force" or "")
                cb({ pulled = 1 })
                return { cancel = function() end }
            end,
        }, { __index = SourceBase })
    end
    local desk = { source = fake("local"), _books_sync = {}, _stats_sync = {}, tab = "library",
        updateView = function() end, onEvent = function() end }
    Sync.rescan(desk)
    Assert.eq(scanned[1], "local:force")
    desk.source = fake("wechat")
    scanned = {}
    Sync.rescan(desk)
    Assert.eq(#scanned, 0)
end

-- 后台上传：同 key 已在上传时第二轮不得并发再起一份，提示「正在执行」。
do
    for i = #rejected, 1, -1 do rejected[i] = nil end
    local starts, bg = 0, nil
    local up = setmetatable({
        id = "up", name = "Up", configured = function() return true end,
        syncBooksAsync = function(_, opts, cb)
            bg = opts.on_background
            cb({ pulled = 0 })
            return { cancel = function() end }
        end,
    }, { __index = SourceBase })
    local desk = { source = up, _books_sync = {}, _stats_sync = {}, tab = "home",
        updateView = function() end, onEvent = function() end }
    local function start(_report, _done) starts = starts + 1; return { cancel = function() end } end
    Sync.open(desk)
    bg(start)
    local task = Tasks.get("books-upload\0up")
    Assert.not_nil(task, "上传经任务队列")
    Assert.eq(starts, 1)
    Assert.eq(task.state, "running")
    Sync.open(desk)
    bg(start)
    Assert.eq(starts, 1, "上传还在执行：不并发第二份")
    Assert.len(rejected, 1)
    Assert.eq(rejected[1].reason, "running")
    Assert.eq(rejected[1].task.key, "books-upload\0up")
    task.cancel()
end

-- 统计句柄归桌面：旧桌面回包不清新句柄，取消不串桌面，迟到回包不清后继请求。
do
    local requests = {}
    local stat_source = setmetatable({
        id = "stats_race", name = "Stats",
        configured = function() return true end,
        capabilities = function() return { stats_pull = true } end,
        syncBooksAsync = function(_self, _opts, cb)
            cb({ skipped = true })
            return { cancel = function() end }
        end,
        syncStatsAsync = function(_self, _opts, cb)
            local request = { cb = cb, cancelled = 0 }
            requests[#requests + 1] = request
            return { cancel = function()
                request.cancelled = request.cancelled + 1
                cb({ pulled = 1 })
            end }
        end,
    }, { __index = SourceBase })
    local events = 0
    local function owner()
        return { source = stat_source, tab = "home", _books_sync = {}, _stats_sync = {},
            onEvent = function() events = events + 1 end, updateView = function() end }
    end

    local old, current = owner(), owner()
    Sync.refresh(old)
    old.closed = true
    Sync.refresh(current)
    requests[1].cb({ skipped = true })
    Assert.not_nil(current._stats_sync.stats_race)
    Sync.abort(current, stat_source.id)
    Assert.eq(requests[2].cancelled, 1, "旧桌面回包不丢新桌面的取消句柄")
    Assert.is_nil(current._stats_sync.stats_race)
    Assert.eq(events, 0, "取消句柄同步回调时，请求已经作废")

    local a, b = owner(), owner()
    Sync.refresh(a)
    Sync.refresh(b)
    Sync.abort(a, stat_source.id)
    Assert.eq(requests[3].cancelled, 1)
    Assert.eq(requests[4].cancelled, 0, "取消只作用于调用方桌面")
    Assert.not_nil(b._stats_sync.stats_race)
    Sync.abort(b, stat_source.id)

    local desk = owner()
    Sync.refresh(desk)
    Sync.abort(desk, stat_source.id)
    Sync.refresh(desk)
    local flight = desk._stats_sync.stats_race
    requests[5].cb({ pulled = 1 })
    Assert.eq(desk._stats_sync.stats_race, flight, "迟到的旧回包不清后继请求")
    Assert.eq(events, 0)
    Sync.abort(desk, stat_source.id)
    Assert.eq(requests[6].cancelled, 1)

    local synchronous_cancelled = 0
    stat_source.syncStatsAsync = function(_self, _opts, cb)
        cb({ skipped = true })
        return { cancel = function() synchronous_cancelled = synchronous_cancelled + 1 end }
    end
    Sync.refresh(desk)
    Assert.is_nil(desk._stats_sync.stats_race, "同步完成不残留句柄")
    Sync.abort(desk, stat_source.id)
    Assert.eq(synchronous_cancelled, 0)
end

return true
