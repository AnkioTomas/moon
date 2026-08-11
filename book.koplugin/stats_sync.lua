--[[--
阅读统计上报：注册设备 + import page_stat。
数据来自 KOReader statistics.sqlite3，走 /index/stats/*。
推送在 UIManager 后台分步执行，避免卡住 UI。

@module koplugin.book.stats_sync
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local StatsDb = require("stats_db")

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

function StatsSync.deviceId()
    return ensureDeviceId()
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
        return false, "未配置"
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
            return finish(opts, false, "未配置")
        end
        if not StatsDb.available() then
            return finish(opts, false, "无阅读统计数据（请启用 KOReader 阅读统计插件）")
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
                    return finish(opts, false, "统计库为空或无法解析 filename（请从 Book 桌面打开过对应书籍）")
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

--- 兼容旧调用：同步上报（仍走 busy 锁；优先用 pushAsync）
--- @param force boolean 忽略节流
function StatsSync.push(api, force)
    if busy then
        return false, "busy"
    end
    if not api or not api.configured or not api:configured() then
        return false, "未配置"
    end
    if not StatsDb.available() then
        return false, "无阅读统计数据（请启用 KOReader 阅读统计插件）"
    end

    local now = os.time()
    if not force and (now - last_push_at) < MIN_INTERVAL then
        return true, "throttled"
    end

    busy = true
    local device_id = ensureDeviceId()
    StatsSync.registerDevice(api)

    local books = StatsDb.bookData()
    local stats = StatsDb.pageStatData(device_id, books)
    if #books == 0 and #stats == 0 then
        busy = false
        return false, "统计库为空或无法解析 filename（请从 Book 桌面打开过对应书籍）"
    end

    local res, err = api:importReadingStats({
        books = buildPayloadBooks(books),
        stats = stats,
        device_id = device_id,
    })
    busy = false
    if not res then
        logger.warn("book.stats_sync import failed", err)
        return false, err
    end
    last_push_at = now
    logger.info(string.format(
        "book.stats_sync imported books=%d stats=%d",
        #books,
        #stats
    ))
    return true, res
end

return StatsSync
