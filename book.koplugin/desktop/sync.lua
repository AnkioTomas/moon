--[[--
桌面驱动的书架 / 统计同步：桌面可见时后台同步，图书馆刷新时强制同步。
什么时候同步、在飞状态、过期结果丢弃、刷新哪个页签都归桌面；源只提供
``syncBooksAsync`` / ``syncStatsAsync``。在飞状态挂在桌面实例上，统计节流按源 id 记时间戳。

@module koplugin.book.desktop.sync
--]]

local SourceCapabilities = require("source.base").SourceCapabilities
local Tasks = require("workers.tasks")
local logger = require("utils.log")
local _ = require("gettext")

local Sync = {}

local STATS_REFRESH_INTERVAL = 5 * 60

---@type table<string, number> 源 id → 最近一次统计同步尝试时间
local stats_at = {}

--- 书架同步落地：清桌面在飞标记，按结果刷新图书馆 / 首页。被新一轮取代的旧结果丢弃。
--- 失败不动本地书架（本地是唯一真相）；只有手动刷新才提示，后台同步离线失败是常态。
---@param desktop table
---@param source BookSource
---@param request table 发起时的请求令牌
---@param force boolean|nil 手动刷新
---@param result SyncResult|nil
---@param err any
local function onBooksSynced(desktop, source, request, force, result, err)
    if desktop._books_sync_request ~= request then
        logger.dbg("book shelf refresh result dropped", source.id, "stale")
        return
    end
    desktop._books_sync_request = nil
    desktop._books_sync_cancel = nil
    if desktop.closed or desktop.source ~= source then return end
    if not result then
        logger.warn("book shelf sync failed", source.id, err)
        if force then
            require("ui.themes.widgets.toast"):new{ text = err or _("同步失败") }:show()
        end
        return
    end
    -- 源自己的节流命中表示本地数据未变，不要无意义重建整页。
    if result.skipped then
        logger.dbg("book shelf refresh done", source.id, "skipped", result.reason or "")
        return
    end
    local changed = (result.pulled or 0) + (result.pushed or 0) + (result.hidden or 0)
    logger.dbg("book shelf refresh done", source.id, "changed", changed)
    -- 计数全 0 = 本地书架未变。非 0 也可能只是全量对账，首页组件自己比对显示数据再决定重建。
    if changed == 0 then return end
    desktop:onEvent("shelf_changed")
    if desktop.tab == "library" then desktop:updateView() end
end

--- 同步书架。手动刷新（force）进任务队列并前台跟随；自动后台同步不入队，免得每次开桌面都弹窗。
---@param desktop table
---@param source BookSource
---@param force boolean|nil
local function syncBooks(desktop, source, force)
    if desktop._books_sync_request and not force then
        logger.dbg("book shelf refresh skipped", source.id, "pending")
        return
    end
    local key = "books\0" .. tostring(source.id)
    -- 同源手动刷新已在执行：按队列规则拒绝。必须在改桌面在飞状态之前判断，否则执行中那条的结果会被当成过期丢弃。
    -- 还在排队的那条就是下面的 _books_sync_cancel，取消后重新入队即替换。
    local existing = force and Tasks.get(key)
    if existing and existing.state ~= "queued" then
        require("workers.ui.task_dialog").rejected("running", existing)
        return
    end
    if desktop._books_sync_cancel then
        logger.dbg("book shelf refresh cancel previous", source.id)
        desktop._books_sync_cancel:cancel()
    end
    logger.dbg("book shelf refresh start", source.id, force and "forced" or "background")
    local request = {}
    desktop._books_sync_request = request
    local function run(report, finish)
        return source:syncBooksAsync({
            force = force,
            on_progress = function(text, done, total)
                if desktop._books_sync_request ~= request then return end
                report(text, done, total)
            end,
        }, function(result, err)
            finish({ ok = result ~= nil, err = err })
            onBooksSynced(desktop, source, request, force, result, err)
        end)
    end
    -- 队列满时退回直接跑。
    local job = force and Tasks.enqueue{ key = key, kind = "sync", title = source.name, run = run }
    if job then
        require("workers.ui.task_dialog").follow(job)
    else
        local noop = function() end
        job = run(noop, noop)
    end
    -- 某些源会同步回调；避免把已完成的 job 句柄残留到桌面状态。
    if desktop._books_sync_request == request then
        desktop._books_sync_cancel = job
    end
end

--- 后台双向同步统计；成功后作废依赖本地 reading_stats 的桌面缓存。
---@param desktop table
---@param source BookSource
---@param force boolean|nil
local function syncStats(desktop, source, force)
    if not SourceCapabilities.supportsStatsPull(source) and type(source.pushStatsAsync) ~= "function" then
        return
    end
    if desktop._stats_sync_pending then
        logger.dbg("book stats sync skipped", source.id, "pending")
        return
    end
    local last = stats_at[source.id]
    if not force and last and os.time() - last < STATS_REFRESH_INTERVAL then
        logger.dbg("book stats sync skipped", source.id, "throttled")
        return
    end
    logger.dbg("book stats sync start", source.id)
    stats_at[source.id] = os.time()
    desktop._stats_sync_pending = true
    source:syncStatsAsync(nil, function(result, err)
        desktop._stats_sync_pending = false
        if desktop.closed or desktop.source ~= source then return end
        if not result then
            logger.warn("book stats sync failed", source.id, err)
            return
        end
        if result.skipped or (result.pulled or 0) + (result.pushed or 0) == 0 then return end
        desktop:onEvent("stats_changed")
        if desktop.tab == "insight" then desktop:updateView() end
    end)
end

--- 桌面变为可见（新开 / 换源）：后台同步统计（5 分钟节流）与书架。首页先读本地数据，成功后由回调刷新。
---@param desktop table
function Sync.open(desktop)
    local source = desktop.source
    if not source or not source:configured() then return end
    syncStats(desktop, source)
    syncBooks(desktop, source)
end

--- 图书馆手动刷新：强制同步。源未配置时说明原因，源有设置入口就提供直达按钮。
---@param desktop table
function Sync.refresh(desktop)
    local source = desktop.source
    if not source then return end
    if not source:configured() then
        local text = _("请先完成数据源设置，再刷新书库。")
        local setting = require("desktop.pages.setting.source").loadSetting(source.id)
        if setting and type(setting.open) == "function" then
            require("ui.themes.widgets.confirm"):new{
                text = text,
                ok_text = _("立即设置"),
                ok_callback = function() setting.open(desktop.plugin) end,
            }:show()
        else
            require("ui.themes.widgets.toast"):new{ text = text }:show()
        end
        return
    end
    syncStats(desktop, source, true)
    syncBooks(desktop, source, true)
end

return Sync
