--[[--
阅读统计上报：注册设备 + import page_stat。
数据来自 KOReader statistics.sqlite3，走 /index/stats/*。
推送在 UIManager 后台分步执行，避免卡住 UI。

@module koplugin.book.stats_sync
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local StatsDb = require("stats_db")
local MoonSettings = require("moon.settings")
local _ = require("gettext")

local StatsSync = {}

-- 避免关书+休眠连打两次
local last_push_at = 0
local MIN_INTERVAL = 20
local busy = false

-- 分步进度：注册 → 读书籍 → 读 page_stat → 上传 → 完成
local PROGRESS_MAX = 5

local function ensureDeviceId()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then
        return id
    end
    -- KOReader 通常已有 device_id；缺失时本地生成并持久化
    id = string.format(
        "book-%08x%08x",
        math.floor(math.random() * 0xffffffff),
        os.time() % 0xffffffff
    )
    G_reader_settings:saveSetting("device_id", id)
    return id
end

function StatsSync.deviceModel()
    return tostring(Device.model or Device.device_name or "KOReader")
end

function StatsSync.isBusy()
    return busy
end

function StatsSync.progressMax()
    return PROGRESS_MAX
end

--- 注册设备（失败只记日志）
function StatsSync.registerDevice(api)
    if not api or not api.configured or not api:configured() then
        return false, _("未配置")
    end
    local id = ensureDeviceId()
    local res, err = api:registerReadingDevice(id, StatsSync.deviceModel())
    if not res then
        logger.warn("book.stats_sync register device failed", err)
        return false, err
    end
    return true
end

local function buildPayloadBooks(books)
    local payload_books = {}
    for _, b in ipairs(books) do
        table.insert(payload_books, {
            filename = b.filename,
            title = b.title,
            authors = b.authors,
        })
    end
    return payload_books
end

local function reportProgress(opts, step, label)
    if opts and opts.on_progress then
        pcall(opts.on_progress, step, PROGRESS_MAX, label)
    end
end

local function finish(opts, ok, err)
    busy = false
    if opts and opts.on_done then
        pcall(opts.on_done, ok, err)
    end
end

local function schedule(fn)
    UIManager:scheduleIn(0, fn)
end

--- 后台分步上报。调用后立即返回；结果走 on_done。
--- @param api table
--- @param opts table|nil { force, on_progress(step,max,label), on_done(ok,err) }
function StatsSync.pushAsync(api, opts)
    opts = opts or {}
    if busy then
        if opts.on_done then
            schedule(function()
                opts.on_done(false, "busy")
            end)
        end
        return false, "busy"
    end
    busy = true

    schedule(function()
        if not api or not api.configured or not api:configured() then
            return finish(opts, false, _("未配置"))
        end
        if not StatsDb.available() then
            return finish(opts, false, _("无阅读统计数据（请启用 KOReader 阅读统计插件）"))
        end

        local now = os.time()
        if not opts.force and (now - last_push_at) < MIN_INTERVAL then
            return finish(opts, true, "throttled")
        end

        reportProgress(opts, 1, "register")
        StatsSync.registerDevice(api)

        schedule(function()
            reportProgress(opts, 2, "books")
            local books = StatsDb.bookData()

            schedule(function()
                reportProgress(opts, 3, "stats")
                local device_id = ensureDeviceId()
                local stats = StatsDb.pageStatData(device_id, books)
                if #books == 0 and #stats == 0 then
                    return finish(opts, false, _("统计库为空或无法解析 filename（请从 Book 桌面打开过对应书籍）"))
                end

                schedule(function()
                    reportProgress(opts, 4, "upload")
                    local res, err = api:importReadingStats({
                        books = buildPayloadBooks(books),
                        stats = stats,
                        device_id = device_id,
                    })
                    if not res then
                        logger.warn("book.stats_sync import failed", err)
                        return finish(opts, false, err)
                    end

                    last_push_at = os.time()
                    reportProgress(opts, 5, "done")
                    logger.info(string.format(
                        "book.stats_sync imported books=%d stats=%d",
                        #books,
                        #stats
                    ))
                    return finish(opts, true, res)
                end)
            end)
        end)
    end)

    return true
end

--- 带 UI 的上报：自动/手动都走后台分步；手动才弹进度条。
--- @param api table 数据源
--- @param show_msg boolean 是否提示用户
--- @param force boolean 忽略节流与「自动上报」开关
function StatsSync.pushWithUi(api, show_msg, force)
    if MoonSettings.get().auto_stats == false and not force then
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
        -- 联网成功后再弹进度条，避免取消 Wi-Fi 后对话框挂死
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
                    else
                        text = err or _("统计上传失败")
                    end
                    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
                elseif not ok and err ~= "throttled" and err ~= "busy" then
                    logger.warn("book push reading stats failed", err)
                end
            end,
        })
    end)
end

return StatsSync
