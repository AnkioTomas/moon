--[[--
阅读统计上报：读本地 reading_stats（stats.tracker 采集），经 Source.importReadingStatsAsync 上传。
数据按 source_id 隔离，只上报当前源的书；上传成功即删本地记录。

@module koplugin.book.stats.stats_sync
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local _ = require("gettext")
local StatsDB = require("utils.db.stats")
local DbQueue = require("utils.db.queue")

local StatsSync = {}

local last_push_at = 0
local MIN_INTERVAL = 20
local busy = false
local generation = 0
local active_token = nil
local active_job = nil
local active_opts = nil
local PROGRESS_MAX = 3

--- 设备型号字符串。
---@return string
function StatsSync.deviceModel()
    return tostring(Device.model or Device.device_name or "KOReader")
end

--- 是否正在上报。
---@return boolean
function StatsSync.isBusy()
    return busy
end

--- 上报进度条上限步数。
---@return number
function StatsSync.progressMax()
    return PROGRESS_MAX
end

--- 数据源是否支持阅读统计导入。
---@param api table|nil
---@return boolean
function StatsSync.supportsImport(api)
    local caps = api and api.capabilities and api:capabilities() or {}
    return caps.stats_import == true
end

--- 确保本地 device_id 存在（无则生成并写入设置）。
---@return string
local function ensureDeviceId()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then
        return id
    end
    id = string.format(
        "book-%08x%08x",
        math.floor(math.random() * 0xffffffff),
        os.time() % 0xffffffff
    )
    G_reader_settings:saveSetting("device_id", id)
    return id
end

--- Register device through the source's nonblocking transport.
---@param api table
---@param cb fun(ok: boolean, err: any)
---@return table|nil
function StatsSync.registerDeviceAsync(api, cb)
    if not StatsSync.supportsImport(api) then
        cb(false, "unsupported")
        return nil
    end
    if not api or not api.configured or not api:configured() then
        cb(false, _("未配置"))
        return nil
    end
    if not api.registerReadingDeviceAsync then
        cb(false, "unsupported")
        return nil
    end
    local id = ensureDeviceId()
    return api:registerReadingDeviceAsync(id, StatsSync.deviceModel(), function(res, err)
        if not res then
            logger.warn("book.stats_sync register device failed", err)
            cb(false, err)
            return
        end
        cb(true)
    end)
end

--- 回调上报进度（若 opts.on_progress 存在）。
---@param opts table|nil
---@param step number
---@param label string
local function reportProgress(opts, step, label)
    if opts and opts.on_progress then
        pcall(opts.on_progress, step, PROGRESS_MAX, label)
    end
end

--- 结束上报：清 busy 并回调 on_done。
---@param opts table|nil
---@param ok boolean
---@param err any
local function finish(opts, token, ok, err)
    if active_token ~= token then
        return
    end
    busy = false
    active_token = nil
    active_job = nil
    active_opts = nil
    if opts and opts.on_done then
        pcall(opts.on_done, ok, err)
    end
end

--- Invalidate callbacks tied to the previous source instance.
function StatsSync.invalidate()
    generation = generation + 1
    if active_job and active_job.cancel then
        active_job.cancel()
    end
    local opts = active_opts
    active_job = nil
    active_token = nil
    active_opts = nil
    busy = false
    if opts and opts.on_done then
        pcall(opts.on_done, false, "cancelled")
    end
end

--- 读当前源待上报行并组装载荷。
---@param source_id string
---@param device_id string
---@return table[] books, table[] stats, number[] ids
local function buildPayload(source_id, device_id)
    local rows = StatsDB.allBySource(source_id)
    local books, stats, ids = {}, {}, {}
    local seen = {}
    for _, row in ipairs(rows) do
        ids[#ids + 1] = row.id
        if not seen[row.stable_id] then
            seen[row.stable_id] = true
            books[#books + 1] = { stable_id = row.stable_id }
        end
        stats[#stats + 1] = {
            stable_id = row.stable_id,
            page = row.page,
            start_time = row.start_time,
            duration = row.duration,
            total_pages = row.total_pages,
            device_id = device_id,
        }
    end
    return books, stats, ids
end

--- 后台分步上报。调用后立即返回；结果走 on_done。
---@param api table
---@param opts table|nil { force, on_progress(step,max,label), on_done(ok,err) }
---@return boolean, string|nil
function StatsSync.pushAsync(api, opts)
    opts = opts or {}
    if not StatsSync.supportsImport(api) then
        return false, "unsupported"
    end
    if busy then
        if opts.on_done then
            UIManager:nextTick(function()
                opts.on_done(false, "busy")
            end)
        end
        return false, "busy"
    end
    busy = true
    local token = generation + 1
    generation = token
    active_token = token
    active_opts = opts
    local source_id = api and api.id

    --- 统一失败收尾。
    ---@param err any
    local function on_err(err)
        if active_token ~= token or not api or api.id ~= source_id then
            return
        end
        if err ~= "throttled" and err ~= "busy" then
            logger.warn("book.stats_sync failed", err)
        end
        finish(opts, token, false, err)
    end

    if not api or not api.configured or not api:configured() then
        on_err(_("未配置"))
        return false, _("未配置")
    end
    if not api.importReadingStatsAsync then
        on_err("unsupported")
        return false, "unsupported"
    end
    if StatsDB.countBySource(source_id) == 0 then
        on_err(_("无阅读统计数据"))
        return false, _("无阅读统计数据")
    end
    if not opts.force and (os.time() - last_push_at) < MIN_INTERVAL then
        finish(opts, token, true, "throttled")
        return true
    end

    reportProgress(opts, 1, "register")
    local device_id = ensureDeviceId()
    local register_job = StatsSync.registerDeviceAsync(api, function(registered, register_err)
        if active_token ~= token or api.id ~= source_id then
            return
        end
        if not registered then
            on_err(register_err)
            return
        end
        reportProgress(opts, 2, "upload")
        -- register 的网络往返后重读：关书时刚落盘的最后一条也能搭上
        local books, stats, ids = buildPayload(source_id, device_id)
        if #stats == 0 then
            on_err(_("无阅读统计数据"))
            return
        end
        active_job = api:importReadingStatsAsync({
            books = books,
            stats = stats,
            device_id = device_id,
        }, function(res, err)
            if active_token ~= token or api.id ~= source_id then
                return
            end
            if not res then
                on_err(err)
                return
            end
            last_push_at = os.time()
            DbQueue.run(function()
                StatsDB.deleteIds(ids)
            end)
            reportProgress(opts, 3, "done")
            logger.info(string.format(
                "book.stats_sync imported books=%d stats=%d",
                #books, #stats
            ))
            finish(opts, token, true, res)
        end)
    end)
    -- Async source implementations normally invoke the callback later. Do not
    -- overwrite a child job when a validation failure invokes it immediately.
    if active_token == token and active_job == nil then
        active_job = register_job
    end

    return true
end

--- 带 UI 的上报：自动/手动都走后台分步；手动才弹进度条。
---@param api table
---@param show_msg boolean
---@param force boolean
function StatsSync.pushWithUi(api, show_msg, force)
    if not StatsSync.supportsImport(api) then
        return
    end
    if StatsSync.isBusy() then
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = _("阅读统计正在上报…"),
                timeout = 2,
            })
        end
        return
    end

    NetworkMgr:runWhenOnline(function()
        local dialog
        if show_msg then
            local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
            if ok_dlg and ProgressbarDialog then
                dialog = ProgressbarDialog:new{
                    title = _("正在上报阅读统计…"),
                    subtitle = _("读取本地统计并上传"),
                    progress_max = StatsSync.progressMax(),
                    refresh_time_seconds = 0.05,
                    dismissable = false,
                }
                dialog:show()
            else
                UIManager:show(InfoMessage:new{
                    text = _("正在上报阅读统计…"),
                    timeout = 1,
                })
            end
        end

        StatsSync.pushAsync(api, {
            force = force,
            on_progress = function(step)
                if dialog then
                    dialog:reportProgress(step)
                end
            end,
            on_done = function(ok, err)
                if dialog then
                    if ok and err ~= "throttled" then
                        dialog:reportProgress(StatsSync.progressMax())
                    end
                    dialog:close()
                    dialog = nil
                end
                if show_msg then
                    local text
                    if ok and err == "throttled" then
                        text = _("统计上报已节流，稍后再试")
                    elseif ok then
                        text = _("阅读统计已上传")
                    elseif err == "busy" then
                        text = _("阅读统计正在上报…")
                    elseif err == "cancelled" then
                        return
                    else
                        text = err or _("统计上传失败")
                    end
                    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
                elseif not ok and err ~= "throttled" and err ~= "busy" and err ~= "cancelled" then
                    logger.warn("book push reading stats failed", err)
                end
            end,
        })
    end)
end

return StatsSync
