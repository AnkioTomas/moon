--[[--
桌面驱动的书架 / 统计同步：桌面可见时后台同步，图书馆刷新时强制同步。
什么时候同步、在飞状态、过期结果丢弃、刷新哪个页签都归桌面；源只提供
``syncBooksAsync`` / ``syncStatsAsync``。同步范围跟图书馆展示范围一致：混合模式是全部已启用源，
否则只有活跃源。在飞状态按源 id 挂在桌面实例上，统计节流按源 id 记时间戳。

@module koplugin.book.desktop.sync
--]]

local MoonSettings = require("utils.settings")
local Registry = require("source.registry")
local Auth = require("source.auth")
local SourceCapabilities = require("source.base").SourceCapabilities
local Tasks = require("workers.tasks")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local Sync = {}

-- 打开桌面时后台同步的节流（秒）：统计，以及混合模式下全部源的书架；手动刷新不受限。
local BACKGROUND_SYNC_INTERVAL = 5 * 60

---@type table<string, number> 源 id → 最近一次统计同步尝试时间
local stats_at = {}

---@type table<string, number> 源 id → 混合模式最近一次书架后台同步时间
local books_at = {}

---@type table<string, string> 源 id → 已提示过的书架同步错误；同步干净成功后清掉
local reported = {}

---@return boolean
local function mixed()
    return MoonSettings.get("source").library_mixed == true
end

--- 本轮要同步的已配置源：混合模式 = 全部已启用源，否则只有活跃源。加载失败的源跳过。
---@param desktop table
---@return BookSource[]
---@param background boolean|nil 后台同步：跳过登录已失效的源（等用户重新登录或手动刷新）
local function targets(desktop, background)
    local function usable(source)
        return source and source:configured() and not (background and Auth.expired(source.id))
    end
    local list = {}
    if not mixed() then
        if usable(desktop.source) then list[1] = desktop.source end
        return list
    end
    for _idx, meta in ipairs(Registry.listEnabled()) do
        local source = Registry.resolve(meta.id)
        if usable(source) then list[#list + 1] = source end
    end
    return list
end

--- 结果还归不归当前桌面：换源 / 退出混合 / 停用该源之后，旧源的结果不落到新页面上。
---@param desktop table
---@param source BookSource
---@return boolean
local function inScope(desktop, source)
    if desktop.closed then return false end
    if mixed() then return Registry.isEnabled(source.id) end
    return desktop.source == source
end

--- 书架同步出错的提示：手动刷新每次都提示；后台同步只在联网时提示（离线失败是常态），
--- 同一源同一条错误本次运行只提示一次，免得每次打开桌面都弹。err 为 nil 表示这轮干净成功。
---@param source BookSource
---@param force boolean|nil
---@param err any
local function report(source, force, err)
    if not err then reported[source.id] = nil; return end
    -- 登录失效由 Sync.promptLogin 的弹窗负责，后台不再叠加 toast。
    if not force and Auth.expired(source.id) then return end
    err = tostring(err)
    if not force and (reported[source.id] == err or not require("ui/network/manager"):isConnected()) then return end
    reported[source.id] = err
    require("ui.themes.widgets.toast"):new{ text = err }:show()
end

--- 书架同步落地：清该源在飞标记，按结果刷新图书馆 / 首页。被新一轮取代的旧结果丢弃。
--- 失败不动本地书架（本地是唯一真相），只按 report 的规则提示。
---@param desktop table
---@param source BookSource
---@param flight table 发起时的在飞记录
---@param force boolean|nil 手动刷新
---@param result SyncResult|nil
---@param err any
local function onBooksSynced(desktop, source, flight, force, result, err)
    if desktop._books_sync[source.id] ~= flight then
        logger.dbg("book shelf refresh result dropped", source.id, "stale")
        return
    end
    desktop._books_sync[source.id] = nil
    if not inScope(desktop, source) then return end
    if not result then
        logger.warn("book shelf sync failed", source.id, err)
        report(source, force, err or _("同步失败"))
        return
    end
    report(source, force, result.push_error)
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

--- 同步书架。手动刷新（force）进任务队列，follow 时前台跟随；自动后台同步不入队，免得每次开桌面都弹窗。
---@param desktop table
---@param source BookSource
---@param force boolean|nil
---@param follow boolean|nil 手动刷新时弹前台进度窗
local function syncBooks(desktop, source, force, follow)
    local current = desktop._books_sync[source.id]
    if current and not force then
        logger.dbg("book shelf refresh skipped", source.id, "pending")
        return
    end
    local key = "books\0" .. tostring(source.id)
    -- 同源手动刷新已在执行：按队列规则拒绝。必须在改在飞状态之前判断，否则执行中那条的结果会被当成过期丢弃。
    -- 还在排队的那条就是 current.cancel，取消后重新入队即替换。
    local existing = force and Tasks.get(key)
    if existing and existing.state ~= "queued" then
        require("workers.ui.task_dialog").rejected("running", existing)
        return
    end
    if current and current.cancel then
        logger.dbg("book shelf refresh cancel previous", source.id)
        current.cancel:cancel()
    end
    logger.dbg("book shelf refresh start", source.id, force and "forced" or "background")
    local flight = {}
    desktop._books_sync[source.id] = flight
    local function run(progress, finish)
        return source:syncBooksAsync({
            force = force,
            on_progress = function(text, done, total)
                if desktop._books_sync[source.id] ~= flight then return end
                progress(text, done, total)
            end,
            on_background = function(start)
                -- 本地新书已入库可读；上传进任务队列，顶栏可见进度，传完刷新书架（身份并成云端书）。
                local upload = Tasks.enqueue{
                    key = "books-upload\0" .. tostring(source.id), kind = "sync",
                    title = source.name .. " · " .. _("上传"),
                    run = function(report, finish)
                        return start(report, function(up_err)
                            finish({ ok = up_err == nil, err = up_err })
                            if desktop.closed then return end
                            desktop:onEvent("shelf_changed")
                            if desktop.tab == "library" then desktop:updateView() end
                        end)
                    end,
                }
                if not upload then start(function() end, function() end) end
            end,
        }, function(result, err)
            finish({ ok = result ~= nil, err = err })
            onBooksSynced(desktop, source, flight, force, result, err)
        end)
    end
    -- 队列满时退回直接跑。
    local job = force and Tasks.enqueue{ key = key, kind = "sync", title = source.name, run = run }
    if job then
        if follow then require("workers.ui.task_dialog").follow(job) end
    else
        local noop = function() end
        job = run(noop, noop)
    end
    -- 某些源会同步回调；避免把已完成的 job 句柄残留到桌面状态。
    if desktop._books_sync[source.id] == flight then
        flight.cancel = job
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
    if desktop._stats_sync[source.id] then
        logger.dbg("book stats sync skipped", source.id, "pending")
        return
    end
    local last = stats_at[source.id]
    if not force and last and os.time() - last < BACKGROUND_SYNC_INTERVAL then
        logger.dbg("book stats sync skipped", source.id, "throttled")
        return
    end
    logger.dbg("book stats sync start", source.id)
    stats_at[source.id] = os.time()
    desktop._stats_sync[source.id] = true
    source:syncStatsAsync(nil, function(result, err)
        desktop._stats_sync[source.id] = nil
        if not inScope(desktop, source) then return end
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
    local is_mixed = mixed()
    for _idx, source in ipairs(targets(desktop, true)) do
        syncStats(desktop, source)
        local last = books_at[source.id]
        if is_mixed and last and os.time() - last < BACKGROUND_SYNC_INTERVAL then
            logger.dbg("book shelf refresh skipped", source.id, "throttled")
        else
            if is_mixed then books_at[source.id] = os.time() end
            syncBooks(desktop, source)
        end
    end
end

--- 本地文件有变（远程管理上传 / 删除等）：悄悄重扫本地书籍源，书架不用手动刷新。
--- 不弹进度窗；本地源的同步已在执行时跳过（那一轮之后下次打开桌面会再扫）。
---@param desktop table
function Sync.rescan(desktop)
    for _idx, source in ipairs(targets(desktop)) do
        if source.id == "local" then
            local running = Tasks.get("books\0local")
            if not (running and running.state ~= "queued") then syncBooks(desktop, source, true) end
        end
    end
end

--- 图书馆手动刷新：强制同步。单源模式下源未配置时说明原因，源有设置入口就提供直达按钮；
--- 混合模式只刷已配置的源，多个源一起刷时不逐个弹进度窗，进度看顶栏任务。
---@param desktop table
function Sync.refresh(desktop)
    local source = desktop.source
    if not source then return end
    if not mixed() and not source:configured() then
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
    local list = targets(desktop)
    if #list == 0 then
        -- 混合模式下一个已配置的源都没有：说明原因，不要毫无反应。
        require("ui.themes.widgets.toast"):new{ text = _("请先完成数据源设置，再刷新书库。") }:show()
        return
    end
    for _idx, target in ipairs(list) do
        syncStats(desktop, target, true)
        books_at[target.id] = os.time()
        syncBooks(desktop, target, true, #list == 1)
    end
    if #list > 1 then
        require("ui.themes.widgets.toast"):new{
            text = T(_("正在同步 %1 个数据源，可在顶栏查看进度"), #list), timeout = 2,
        }:show()
    end
end

--- 源登录失效（静默续期失败）时引导重新登录。由 main 经 ``source.auth`` 注入；
--- 每个源每次运行最多弹一次（见 source.auth）；源设置有 login / open 就给直达按钮。
---@param plugin table
---@param id string
---@param msg string|nil
function Sync.promptLogin(plugin, id, msg)
    require("ui/uimanager"):nextTick(function()
        local meta = Registry.meta(id)
        local name = meta and meta.name or id
        local text = T(_("%1 登录已失效，请重新登录。后台同步会暂停该数据源，直到重新登录。"), name)
        if msg and msg ~= "" then text = text .. "\n\n" .. msg end
        local setting = require("desktop.pages.setting.source").loadSetting(id)
        local login = setting and (setting.login or setting.open)
        if type(login) == "function" then
            require("ui.themes.widgets.confirm"):new{
                text = text,
                ok_text = _("重新登录"),
                ok_callback = function() login(plugin) end,
            }:show()
        else
            require("ui.themes.widgets.toast"):new{ text = text }:show()
        end
    end)
end

return Sync
