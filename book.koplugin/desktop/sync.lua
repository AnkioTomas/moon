--[[--
桌面驱动的书架 / 统计同步：桌面可见时后台同步，图书馆单击增量刷新、长按全量刷新。
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

--- 连接暂不可用（唤醒后常见：isConnected 已真，TCP/路由还不通，错误也可能只有 -1）。
--- 后台同步不弹，并延迟再试；认证错误仍提示。
---@param err any
---@return boolean
local function localNetDown(err)
    err = tostring(err or "")
    if err:find("网络不可用", 1, true) or err:find("DNS resolv error", 1, true) then
        return true
    end
    local lower = err:lower()
    for _idx, needle in ipairs({
        "could not connect",
        "network is unreachable", "no route to host", "network is down",
        "host is unreachable", "connection refused",
    }) do
        if lower:find(needle, 1, true) then return true end
    end
    return false
end

-- 唤醒半联网时 isConnected 往往已经为真，不会再收到 NetworkConnected；失败后过几秒再试一两次。
local RETRY_DELAYS = { 3, 8 }

local retry_tick, retry_desktop
local retry_step = 0
local opening_from_retry = false

local function cancelRetry()
    if retry_tick then
        require("ui/uimanager"):unschedule(retry_tick)
        retry_tick = nil
    end
    retry_desktop = nil
    retry_step = 0
end

local function runRetry()
    local desktop = retry_desktop
    retry_tick, retry_desktop = nil, nil
    if not desktop or desktop.closed or desktop.active == false then
        retry_step = 0
        return
    end
    opening_from_retry = true
    Sync.open(desktop)
    opening_from_retry = false
end

---@param desktop table
local function scheduleRetry(desktop)
    if not desktop or desktop.closed or desktop.active == false then return end
    if retry_tick then return end
    local delay = RETRY_DELAYS[retry_step + 1]
    if not delay then
        retry_step = 0
        return
    end
    retry_step = retry_step + 1
    retry_desktop = desktop
    retry_tick = runRetry
    require("ui/uimanager"):scheduleIn(delay, retry_tick)
end

--- 书架同步出错的提示：手动刷新（增量与全量）每次都提示；后台同步只在联网且是对端/配置问题时提示
--- （离线、唤醒半联网是常态，不打扰），同一源同一条错误本次运行只提示一次。
--- err 为 nil 表示这轮干净成功。
---@param source BookSource
---@param manual boolean|nil
---@param err any
local function report(source, manual, err)
    if not err then reported[source.id] = nil; return end
    -- 登录失效由 Sync.promptLogin 的弹窗负责，后台不再叠加 toast。
    if not manual and Auth.expired(source.id) then return end
    err = tostring(err)
    if not manual and (reported[source.id] == err
            or not require("ui/network/manager"):isConnected()
            or localNetDown(err)) then
        return
    end
    reported[source.id] = err
    require("ui.themes.widgets.toast"):new{ text = err }:show()
end

--- 书架同步落地：清该源在飞标记，按结果刷新图书馆 / 首页。被新一轮取代的旧结果丢弃。
--- 失败不动本地书架（本地是唯一真相），只按 report 的规则提示。
---@param desktop table
---@param source BookSource
---@param flight table 发起时的在飞记录
---@param manual boolean|nil 手动刷新（增量与全量）：每次都提示错误
---@param result SyncResult|nil
---@param err any
local function onBooksSynced(desktop, source, flight, manual, result, err)
    if desktop._books_sync[source.id] ~= flight then
        logger.dbg("book shelf refresh result dropped", source.id, "stale")
        return
    end
    desktop._books_sync[source.id] = nil
    if not inScope(desktop, source) then return end
    if not result then
        logger.warn("book shelf sync failed", source.id, err)
        report(source, manual, err or _("同步失败"))
        if not manual and localNetDown(err) then
            books_at[source.id] = nil
            scheduleRetry(desktop)
        end
        return
    end
    report(source, manual, result.push_error)
    if not manual and result.push_error and localNetDown(result.push_error) then
        books_at[source.id] = nil
        scheduleRetry(desktop)
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

--- 同步书架。queued 时入任务队列，follow 时前台跟随；force 为源级全量。
--- 自动后台同步不入队，免得每次开桌面都弹窗。
---@param desktop table
---@param source BookSource
---@param opts { force?: boolean, follow?: boolean, queued?: boolean, title?: string }|nil
local function syncBooks(desktop, source, opts)
    opts = opts or {}
    local force = opts.force == true
    local follow = opts.follow == true
    local queued = opts.queued == true
    local current = desktop._books_sync[source.id]
    if current and not queued then
        logger.dbg("book shelf refresh skipped", source.id, "pending")
        return
    end
    local key = "books\0" .. tostring(source.id)
    -- 同源手动刷新已在执行：按队列规则拒绝。必须在改在飞状态之前判断，否则执行中那条的结果会被当成过期丢弃。
    -- 还在排队的那条就是 current.cancel，取消后重新入队即替换。
    local existing = queued and Tasks.get(key)
    if existing and existing.state ~= "queued" then
        require("workers.ui.task_dialog").rejected("running", existing)
        return
    end
    if current and current.cancel then
        logger.dbg("book shelf refresh cancel previous", source.id)
        current.cancel:cancel()
    end
    local mode = force and "forced" or (queued and "incremental" or "background")
    logger.dbg("book shelf refresh start", source.id, mode)
    local flight = {}
    desktop._books_sync[source.id] = flight
    local function run(progress, finish)
        return source:syncBooksAsync({
            force = force or nil,
            manual = queued or nil,
            on_changed = function()
                -- 补全 / 对齐写库后首页要重读；桌面已关（人在阅读器里）就等下一次自然事件。
                if desktop.closed then return end
                desktop:onEvent("shelf_changed")
            end,
            on_progress = function(text, done, total)
                if desktop._books_sync[source.id] ~= flight then return end
                progress(text, done, total)
            end,
            on_background = function(start)
                -- 本地新书已入库可读；上传进任务队列，顶栏可见进度，传完刷新书架（身份并成云端书）。
                local spec = {
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
                local upload, reason = Tasks.enqueue(spec)
                -- 同 key 已在上传：不再并发第二份，剩下的脏书由那一轮或下一轮同步带走；队列满才退回直跑。
                if not upload and reason == "queue_full" then
                    start(function() end, function() end)
                elseif not upload then
                    require("workers.ui.task_dialog").rejected(reason, spec)
                end
            end,
        }, function(result, err)
            finish({ ok = result ~= nil, err = err })
            onBooksSynced(desktop, source, flight, queued, result, err)
        end)
    end
    -- 队列满时退回直接跑。
    local job = queued and Tasks.enqueue{ key = key, kind = "sync", title = opts.title or source.name, run = run }
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
    local flight = {}
    desktop._stats_sync[source.id] = flight
    local job = source:syncStatsAsync(nil, function(result, err)
        if desktop._stats_sync[source.id] ~= flight then return end
        desktop._stats_sync[source.id] = nil
        if not inScope(desktop, source) then return end
        if not result then
            logger.warn("book stats sync failed", source.id, err)
            if not force and localNetDown(err) then
                stats_at[source.id] = nil
                scheduleRetry(desktop)
            end
            return
        end
        if result.skipped or (result.pulled or 0) + (result.pushed or 0) == 0 then return end
        desktop:onEvent("stats_changed")
        if desktop.tab == "insight" then desktop:updateView() end
    end)
    -- 同步回调的源在返回前已经把在飞标记清掉，不要把句柄再挂回去。
    if desktop._stats_sync[source.id] == flight then flight.cancel = job end
end

--- 退出登录：停掉这个源还在飞的书架 / 统计同步，免得回调在清完本地记录之后又写回来。
---@param desktop table
---@param source_id string
function Sync.abort(desktop, source_id)
    local books = desktop._books_sync[source_id]
    local stats = desktop._stats_sync[source_id]
    desktop._books_sync[source_id] = nil
    desktop._stats_sync[source_id] = nil
    if books and books.cancel and books.cancel.cancel then books.cancel:cancel() end
    if stats and stats.cancel and stats.cancel.cancel then stats.cancel:cancel() end
end

--- 桌面变为可见（新开 / 换源）：后台同步统计（5 分钟节流）与书架。首页先读本地数据，成功后由回调刷新。
---@param desktop table
function Sync.open(desktop)
    if not opening_from_retry then cancelRetry() end
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
            if not (running and running.state ~= "queued") then
                syncBooks(desktop, source, { force = true, queued = true })
            end
        end
    end
end

--- 图书馆手动刷新。force 为真时全量（覆盖缓存 / 走全量快照），否则增量。
--- 二者都是用户发起：进任务队列、提示错误、不受后台节流。单源模式下源未配置时说明原因，
--- 源有设置入口就提供直达按钮；混合模式只刷已配置的源，多个源一起刷时不逐个弹进度窗，进度看顶栏任务。
---@param desktop table
---@param force boolean|nil
function Sync.refresh(desktop, force)
    cancelRetry()
    force = force == true
    local source = desktop.source
    if not source then return end
    if not mixed() and not source:configured() then
        require("ui.themes.widgets.confirm"):new{
            text = _("请先完成数据源设置，再刷新书库。"),
            ok_text = _("去登录"),
            ok_callback = function()
                require("desktop.pages.setting.source").openAccount(desktop, source.id)
            end,
        }:show()
        return
    end
    local list = targets(desktop)
    if #list == 0 then
        -- 混合模式下一个已配置的源都没有：打开账号页，不要只 toast。
        require("ui.themes.widgets.confirm"):new{
            text = _("请先完成数据源设置，再刷新书库。"),
            ok_text = _("去登录"),
            ok_callback = function()
                require("desktop.pages.setting.source").openAccount(desktop)
            end,
        }:show()
        return
    end
    local label = force and _("全量刷新") or _("增量刷新")
    for _idx, target in ipairs(list) do
        syncStats(desktop, target, true)
        books_at[target.id] = os.time()
        syncBooks(desktop, target, {
            force = force,
            queued = true,
            follow = #list == 1,
            title = target.name .. " · " .. label,
        })
    end
    if #list > 1 then
        local toast = force and _("正在全量同步 %1 个数据源，可在顶栏查看进度")
            or _("正在增量同步 %1 个数据源，可在顶栏查看进度")
        require("ui.themes.widgets.toast"):new{
            text = T(toast, #list), timeout = 2,
        }:show()
    end
end

--- 桌面关闭：取消还在等的半联网重试。
---@param desktop table
function Sync.onClose(desktop)
    if retry_desktop == desktop then cancelRetry() end
end

--- 网络恢复：若正等半联网重试，立刻再同步一次（不另开一轮无限重试）。
---@param desktop table|nil
function Sync.onNetworkConnected(desktop)
    if not retry_tick then return end
    if desktop and retry_desktop and desktop ~= retry_desktop then return end
    require("ui/uimanager"):unschedule(retry_tick)
    runRetry()
end

--- 源登录失效（静默续期失败）时引导重新登录。由 main 经 ``source.auth`` 注入；
--- 每个源每次运行最多弹一次（见 source.auth）；源设置有 login / open 就给直达按钮。
--- 正文永远是中文模板；接口原文（NOT.LOGIN 等）不进弹窗，额外中文说明才附在后面。
---@param plugin table
---@param id string
---@param msg string|nil
function Sync.promptLogin(plugin, id, msg)
    require("ui/uimanager"):nextTick(function()
        local meta = Registry.meta(id)
        local name = meta and meta.name or id
        local text = T(_("%1 登录已失效，请重新登录。后台同步会暂停该数据源，直到重新登录。"), name)
        -- 只附中文说明（扫码提示等）；NOT.LOGIN / HTTP 401 一类接口原文丢掉。
        local detail = Auth.userDetail(msg)
        if detail and detail ~= "" then
            text = text .. "\n\n" .. detail
        end
        local dialog
        local buttons = {
            { text = _("稍后"), callback = function() dialog:close() end },
            {
                text = _("重新登录"), variant = "primary",
                callback = function()
                    dialog:close()
                    local desktop = plugin and plugin.desktop
                    if desktop then
                        require("desktop.pages.setting.source").openAccount(desktop, id)
                    else
                        local setting = require("desktop.pages.setting.source").loadSetting(id)
                        local login = setting and (setting.login or setting.open)
                        if type(login) == "function" then login(plugin) end
                    end
                end,
            },
        }
        dialog = require("ui.themes.widgets.text_viewer"):new{
            title = _("登录已失效"), text = text, fullscreen = false, buttons = buttons,
        }
        dialog:show()
    end)
end

return Sync
