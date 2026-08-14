--[[--
阅读统计上报：读 KOReader statistics.sqlite3，经 Source.importReadingStats 上传。
交给 source 的是 md5（无 title/authors）；moon 源再经 books.md5→filename 转为远端名。

@module koplugin.book.stats.stats_sync
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Promise = require("utils.promise")
local logger = require("logger")
local _ = require("gettext")

local StatsSync = {}

local DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local last_push_at = 0
local MIN_INTERVAL = 20
local busy = false
local PROGRESS_MAX = 5

--- 打开 KOReader statistics.sqlite3。
---@return userdata|nil, string|nil
local function openDb()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil, _("无 sqlite 模块")
    end
    local attr_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if attr_ok and lfs and lfs.attributes(DB_PATH, "mode") ~= "file" then
        return nil, _("无统计数据库")
    end
    local conn = SQ3.open(DB_PATH)
    if not conn then
        return nil, _("打开统计库失败")
    end
    return conn
end

--- 把当前阅读会话统计刷进 statistics.sqlite3。
local function flushStatisticsToDb()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or not ReaderUI.instance then
        return
    end
    local ui = ReaderUI.instance
    if ui and ui.statistics and ui.statistics.is_doc and ui.statistics.insertDB then
        local flushed, err = pcall(function()
            ui.statistics:insertDB()
        end)
        if not flushed then
            logger.warn("book.stats_sync flush failed", err)
        end
    end
end

--- 统计库文件是否存在。
---@return boolean
local function available()
    local attr_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not attr_ok or not lfs then
        return false
    end
    return lfs.attributes(DB_PATH, "mode") == "file"
end

--- 读取本地 book 表：{ id, md5 }[]。
---@return table[]
local function bookData()
    flushStatisticsToDb()
    local conn, err = openDb()
    if not conn then
        logger.dbg("book.stats_sync bookData:", err)
        return {}
    end

    local result, rows = conn:exec([[
        SELECT id, md5
        FROM book
    ]])
    local books = {}
    if rows and rows > 0 and result then
        for i = 1, rows do
            local digest = result[2][i] or ""
            if digest ~= "" then
                table.insert(books, {
                    id = tonumber(result[1][i]) or 0,
                    md5 = digest,
                })
            end
        end
    end
    conn:close()
    return books
end

--- 按本地 book id 查 md5。
---@param books table[]
---@param id number
---@return string|nil
local function md5ByLocalId(books, id)
    for _, book in ipairs(books) do
        if book.id == id then
            return book.md5
        end
    end
    return nil
end

--- 读取 page_stat_data 并映射为上报条目。
---@param device_id string
---@param books table[]
---@return table[] stats { md5, page, start_time, duration, total_pages, device_id }
local function pageStatData(device_id, books)
    local conn, err = openDb()
    if not conn then
        logger.dbg("book.stats_sync pageStatData:", err)
        return {}
    end

    local result, rows = conn:exec([[
        SELECT id_book, page, start_time, duration, total_pages
        FROM page_stat_data
    ]])
    local stats = {}
    if rows and rows > 0 and result then
        for i = 1, rows do
            local digest = md5ByLocalId(books, tonumber(result[1][i]))
            local duration = tonumber(result[4][i]) or 0
            local total_pages = tonumber(result[5][i]) or 0
            if digest and duration > 0 and total_pages > 0 then
                table.insert(stats, {
                    md5 = digest,
                    page = tonumber(result[2][i]) or 0,
                    start_time = tonumber(result[3][i]) or 0,
                    duration = duration,
                    total_pages = total_pages,
                    device_id = device_id,
                })
            end
        end
    end
    conn:close()
    return stats
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

--- 向源注册阅读设备。
---@param api table
---@return boolean, any
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

--- 去重后构造上报 books 载荷（仅 md5）。
---@param books table[]
---@return table[]
local function buildPayloadBooks(books)
    local payload_books = {}
    local seen = {}
    for _, b in ipairs(books) do
        local digest = b.md5
        if type(digest) == "string" and digest ~= "" and not seen[digest] then
            seen[digest] = true
            table.insert(payload_books, { md5 = digest })
        end
    end
    return payload_books
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
local function finish(opts, ok, err)
    busy = false
    if opts and opts.on_done then
        pcall(opts.on_done, ok, err)
    end
end

--- 逐步 Promise：每步 UI 线程 nextTick，避免长时间占死
---@param steps (fun(state: table): table|nil, any)[]
---@param state table
---@param on_ok fun(state: table)
---@param on_err fun(err: any)
local function runSteps(steps, state, on_ok, on_err)
    local i = 1
    --- 执行下一步或收尾。
    local function kick()
        if i > #steps then
            on_ok(state)
            return
        end
        local step = steps[i]
        i = i + 1
        Promise:new(function()
            return step(state)
        end)
            :next(function(next_state)
                state = next_state
                kick()
            end)
            :fail(on_err)
    end
    kick()
end

--- 后台分步上报。调用后立即返回；结果走 on_done。
---@param api table
---@param opts table|nil { force, on_progress(step,max,label), on_done(ok,err) }
---@return boolean, string|nil
function StatsSync.pushAsync(api, opts)
    opts = opts or {}
    if busy then
        if opts.on_done then
            Promise:new(function()
                return nil, "busy"
            end):fail(function(err)
                opts.on_done(false, err)
            end)
        end
        return false, "busy"
    end
    busy = true

    --- 统一失败收尾。
    ---@param err any
    local function on_err(err)
        if err ~= "throttled" and err ~= "busy" then
            logger.warn("book.stats_sync failed", err)
        end
        finish(opts, false, err)
    end

    Promise:new(function()
        if not api or not api.configured or not api:configured() then
            return nil, _("未配置")
        end
        if not available() then
            return nil, _("无阅读统计数据（请启用 KOReader 阅读统计插件）")
        end
        local now = os.time()
        if not opts.force and (now - last_push_at) < MIN_INTERVAL then
            return { throttled = true }
        end
        reportProgress(opts, 1, "register")
        StatsSync.registerDevice(api)
        return {}
    end)
        :next(function(state)
            if state.throttled then
                finish(opts, true, "throttled")
                return
            end
            runSteps({
                function(s)
                    reportProgress(opts, 2, "books")
                    s.books = bookData()
                    return s
                end,
                function(s)
                    reportProgress(opts, 3, "stats")
                    s.device_id = ensureDeviceId()
                    s.stats = pageStatData(s.device_id, s.books)
                    if #s.books == 0 and #s.stats == 0 then
                        return nil, _("统计库为空")
                    end
                    return s
                end,
                function(s)
                    reportProgress(opts, 4, "upload")
                    local res, err = api:importReadingStats({
                        books = buildPayloadBooks(s.books),
                        stats = s.stats,
                        device_id = s.device_id,
                    })
                    if not res then
                        return nil, err
                    end
                    s.res = res
                    s.book_n = #s.books
                    s.stat_n = #s.stats
                    return s
                end,
            }, state, function(s)
                last_push_at = os.time()
                reportProgress(opts, 5, "done")
                logger.info(string.format(
                    "book.stats_sync imported books=%d stats=%d",
                    s.book_n or 0,
                    s.stat_n or 0
                ))
                finish(opts, true, s.res)
            end, on_err)
        end)
        :fail(on_err)

    return true
end

--- 带 UI 的上报：自动/手动都走后台分步；手动才弹进度条。
---@param api table
---@param show_msg boolean
---@param force boolean
function StatsSync.pushWithUi(api, show_msg, force)
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
