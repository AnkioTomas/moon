--[[--
kamare 漫画缓存适配层：探测、能力门面、配置镜像、错误文案、书架投影、删除保护。

kamare 是缓存的唯一执行者与写入者；moon 只读状态、发下载 / 删除 / 队列请求。
kamare 的模块一律在函数内 `pcall(require, …)`，绝不顶层 require、也不持有它的 table：
插件升级 / 重载后旧 table 会失效。探测成功结果进程内记忆，失败不记忆（require 自带缓存）。

@module source.kavita.cache
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("utils.log")

local Cache = {}

---@class KamareProbe
---@field ok boolean
---@field state "missing"|"official"|"incompatible"|"enhanced"
---@field reason string|nil
---@field api_version integer|nil
---@field capabilities table|nil
---@field version string|nil
---@field path string|nil

--- 成功探测的记忆（只存元信息，不存模块 table）。
---@type KamareProbe|nil
local memo

--- 当前进程内已镜像过的配置（base_url\0api_key），失败不写。
---@type string|nil
local mirrored

--- 本次会话的镜像是否失败过（设置页第五态）。
local mirror_failed = false

--- 一次性日志的去重键（同一原因只记一行，状态变化才再记）。
local logged = {}

--- 当前打开的章（kamare 保证同一时刻只有一个 viewer）。
---@type { base_url: string|nil, chapter_id: any }|nil
local active

--- 书架投影记忆，按服务器分开；只由成功写操作 / 手动刷新 / Registry.reload 失效。
---@type table<string, ShelfCacheProjection>
local shelves = {}

--- 上次记录过的暂停原因（按服务器），轮询时只在变化时写日志。
---@type table<string, string>
local pause_reason_logged = {}

--- 记一行日志；同一 key 在本进程内只记一次。
---@param key string
---@param text string
local function logOnce(key, text)
    if logged[key] then return end
    logged[key] = true
    logger.info(text)
end

--- 记一行警告；同一 key 在本进程内只记一次（真实故障不能静默，也不能刷屏）。
---@param key string
---@param text string
local function warnOnce(key, text)
    if logged[key] then return end
    logged[key] = true
    logger.warn(text)
end

--- 能力名清单（排序后按分隔符拼接），日志与设置页共用一份口径。
---@param capabilities table|nil
---@param separator string|nil 缺省逗号（日志）；设置页传「、」
---@return string
function Cache.capabilityNames(capabilities, separator)
    local names = {}
    for name, on in pairs(type(capabilities) == "table" and capabilities or {}) do
        if on == true then names[#names + 1] = tostring(name) end
    end
    table.sort(names)
    if #names == 0 then return "none" end
    return table.concat(names, separator or ",")
end

--- 探测结果每进程（每种结果）一行：四态 + 版本 + 能力；不记 API Key。
---@param probe KamareProbe
local function logProbe(probe)
    local capabilities = Cache.capabilityNames(probe.capabilities)
    local signature = string.format("probe|%s|%s|%s", probe.state, tostring(probe.version), capabilities)
    logOnce(signature, string.format("kamare probe ok=%s state=%s version=%s caps=%s",
        tostring(probe.ok), probe.state, tostring(probe.version), capabilities))
end

---@param ids any
---@return string
local function joinIds(ids)
    if type(ids) ~= "table" then return "-" end
    local parts = {}
    for _idx, id in ipairs(ids) do parts[#parts + 1] = tostring(id) end
    return #parts > 0 and table.concat(parts, ",") or "-"
end

--- 每次缓存写操作一行：<op> + 章 id + code（成功记 ok）。
---@param op string
---@param ids any
---@param code string|nil
local function logWrite(op, ids, code)
    logger.info("cache " .. op .. " cid=" .. joinIds(ids) .. " code=" .. tostring(code or "ok"))
end

--- 目录条目 → chapterId 列表（只用于日志）。
---@param entries table|nil
---@return table
local function entryIds(entries)
    local ids = {}
    for _idx, entry in ipairs(type(entries) == "table" and entries or {}) do
        if type(entry) == "table" then
            ids[#ids + 1] = entry.chapterId or entry.chapter_id or entry.id or "?"
        end
    end
    return ids
end

--- 函数内 require：拿不到就 nil，不抛错。
---@param name string
---@return table|nil
local function loadModule(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    return nil
end

--- 本地封面文件存在才算数（缓存可能已被 kamare 清理）。
---@param path any
---@return boolean
local function fileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

--- 官方 / 旧版 kamare 的查看器是否可用（legacy 通道的触发条件）。
---@return boolean
local function legacyAvailable()
    local viewer = loadModule("kamareimageviewer")
    return type(viewer) == "table" and type(viewer.new) == "function"
end

--- `kamareversion` 返回字符串（发布时写入）；老写法可能是表。
---@return string|nil
local function kamareVersion()
    local ok, value = pcall(require, "kamareversion")
    if not ok then return nil end
    if type(value) == "string" and value ~= "" then return value end
    if type(value) == "table" then
        local version = value.version or value.VERSION
        if type(version) == "string" and version ~= "" then return version end
    end
    return nil
end

--- 模块文件路径：借任一公开函数反查，不扫 package.path。
--- 归一重复斜杠：KOReader 的 `extra_plugin_paths` 带尾斜杠，data 目录里的插件会被拼成
--- `plugins//kamare.koplugin`，原样显示会让人以为路径写错了（文件系统本身不介意）。
---@param mod table
---@return string|nil
local function modulePath(mod)
    for _idx, name in ipairs({ "status", "summary", "enqueue", "delete", "open" }) do
        if type(mod[name]) == "function" then
            local ok, info = pcall(debug.getinfo, mod[name], "S")
            local source = ok and info and info.source
            if type(source) == "string" and source:sub(1, 1) == "@" then
                return (source:sub(2):gsub("/+", "/"))
            end
        end
    end
    return nil
end

---@param mod table
---@return KamareProbe
local function enhancedProbe(mod)
    local api_version = tonumber(mod.api_version)
    local capabilities = type(mod.capabilities) == "table" and mod.capabilities or {}
    local ok = api_version == 1
    return {
        ok = ok,
        state = ok and "enhanced" or "incompatible",
        reason = ok and nil or "major_mismatch",
        api_version = api_version,
        capabilities = capabilities,
        version = kamareVersion(),
        path = modulePath(mod),
    }
end

---@param official boolean
---@return KamareProbe
local function missingProbe(official)
    return {
        ok = false,
        state = official and "official" or "missing",
        reason = "missing",
        api_version = nil,
        capabilities = nil,
        version = kamareVersion(),
        path = nil,
    }
end

--- 清空进程内记忆（测试缝；Registry.reload 不经过这里，探测态本就与源实例无关）。
function Cache.reset()
    memo = nil
    mirrored = nil
    mirror_failed = false
    logged = {}
    shelves = {}
    active = nil
    pause_reason_logged = {}
end

---@return KamareProbe
function Cache.probe()
    if memo then return memo end
    local mod = loadModule("kamarecache")
    if mod then
        local result = enhancedProbe(mod)
        -- 只有增强版值得记：官方 / 不兼容 / 未安装都要能随安装或升级立刻变化。
        if result.ok then memo = result end
        logProbe(result)
        return result
    end
    local result = missingProbe(legacyAvailable())
    logProbe(result)
    return result
end

--- 重新探测（设置页的「重新检测」）：清掉成功记忆再探；结果没变则不重复记日志。
---@return KamareProbe
function Cache.reprobe()
    memo = nil
    return Cache.probe()
end

--- 能力是否可用。`open` 是唯一允许退回 legacy 通道的能力（02 A4）。
---@param cap string|nil
---@return boolean
function Cache.available(cap)
    local probe = Cache.probe()
    if not probe.ok then
        return cap == "open" and legacyAvailable() or false
    end
    if cap == nil then return true end
    local capabilities = probe.capabilities or {}
    if cap == "open" then
        return capabilities.open == true or legacyAvailable()
    end
    return capabilities[cap] == true
end

--- 源配置：只读 base_url / api_key，其它键与缓存无关。
--- settings 模块加载失败是真故障（打包 / 安装坏了）：照旧降级成「未配置」，但要留一行日志。
---@return table
local function config()
    local ok, settings = pcall(require, "utils.settings")
    if not ok or type(settings) ~= "table" or type(settings.getSource) ~= "function" then
        warnOnce("config", "kavita cache settings unavailable")
        return {}
    end
    local value = settings.getSource("kavita")
    return type(value) == "table" and value or {}
end

--- 与 Client.new 同口径：去尾斜杠、去首尾空白。
---@param url any
---@return string|nil
local function normBase(url)
    if type(url) ~= "string" then return nil end
    local text = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if text == "" then return nil end
    return text
end

--- API Key 里的空白一律去掉（粘贴时常带换行 / 空格）。
---@param key any
---@return string|nil
local function normKey(key)
    if type(key) ~= "string" then return nil end
    local text = key:gsub("%s+", "")
    if text == "" then return nil end
    return text
end

--- 当前服务器；未配置返回 nil（调用方按 unknown_server 静默降级）。
---@return string|nil
local function targetBase()
    return normBase(config().base_url)
end

--- 能力对应的 kamare 函数名。
local KAMARE = {
    status = "status",
    summary = "summary",
    resume = "resume_page",
    queue = "queue_state",
    index = "index",
    enqueue = "enqueue",
    delete = "delete",
    estimate = "estimate",
    open = "open",
    server = "register_server",
    chapters = "chapters",
    delete_all = "delete_all",
}

--- 取能力对应的函数：缺能力 / 缺函数一律 unsupported（调用点不各写一套）。
---@param name string
---@return table|nil mod, string|nil code, function|nil fn
local function capability(name)
    local probe = Cache.probe()
    if not probe.ok then return nil, "unsupported" end
    if (probe.capabilities or {})[name] ~= true then return nil, "unsupported" end
    local mod = loadModule("kamarecache")
    if not mod then return nil, "unsupported" end
    local fn = mod[KAMARE[name]]
    if type(fn) ~= "function" then return nil, "unsupported" end
    return mod, nil, fn
end

--- 队列控制是同一个能力下的三个动作。
---@param fn_name string
---@return table|nil mod, string|nil code, function|nil fn
local function queueControl(fn_name)
    local probe = Cache.probe()
    if not probe.ok or (probe.capabilities or {}).queue_control ~= true then
        return nil, "unsupported"
    end
    local mod = loadModule("kamarecache")
    if not mod or type(mod[fn_name]) ~= "function" then return nil, "unsupported" end
    return mod, nil, mod[fn_name]
end

--- 写：把 moon 的服务器地址 + API Key 镜像给 kamare（幂等、不联网、不传 name）。
---@param base_url string|nil
---@param api_key string|nil
---@return string|nil server_key, string|nil code, string|nil message
function Cache.registerServer(base_url, api_key)
    local mod, code, fn = capability("server")
    if not mod then return nil, code end
    local url = normBase(base_url) or targetBase()
    local key = normKey(api_key) or normKey(config().api_key)
    if not url then return nil, "base_url_required" end
    if not key then return nil, "api_key_required" end
    local server_key, err, message = fn({ base_url = url, api_key = key })
    if server_key then
        mirrored = url .. "\0" .. key
        mirror_failed = false
    else
        mirror_failed = true
        logOnce("mirror|" .. tostring(err), "cache mirror failed code=" .. tostring(err))
    end
    return server_key, err, message
end

--- 本次会话内镜像是否失败过（设置页的第五态）。
---@return boolean
function Cache.mirrorFailed()
    return mirror_failed
end

--- 镜像兜底：读路径首次操作前一次；写路径每次幂等重放。
---@param write boolean
---@param base_url string|nil
---@param api_key string|nil
---@return boolean
local function ensureMirror(write, base_url, api_key)
    local probe = Cache.probe()
    if not probe.ok or (probe.capabilities or {}).server ~= true then return false end
    local url = normBase(base_url) or targetBase()
    local key = normKey(api_key) or normKey(config().api_key)
    if not url or not key then return false end
    if not write and mirrored == url .. "\0" .. key then return true end
    return Cache.registerServer(url, key) ~= nil
end

---@param list any
---@param value any
---@return boolean
local function includes(list, value)
    if type(list) ~= "table" then return false end
    for _idx, item in ipairs(list) do
        if tostring(item) == tostring(value) then return true end
    end
    return false
end

--- 这一章是不是正在 kamare 查看器里（删除按钮据此置灰）。
---@param chapter_id any
---@return boolean
function Cache.isChapterOpen(chapter_id)
    if not active then return false end
    if tostring(active.chapter_id) ~= tostring(chapter_id) then return false end
    local base_url = targetBase()
    return base_url == nil or active.base_url == base_url
end

--- 关闭回调包一层：先清 active，再交给调用方（source 写双行进度）。
---@param opts table
---@param base_url string|nil
---@param chapter_id any
---@return table
local function wrapClose(opts, base_url, chapter_id)
    local user_close = opts.on_close
    local wrapped = {}
    for key, value in pairs(opts) do wrapped[key] = value end
    wrapped.on_close = function(page, total)
        if active and tostring(active.chapter_id) == tostring(chapter_id)
            and (base_url == nil or active.base_url == base_url) then
            active = nil
        end
        if user_close then return user_close(page, total) end
    end
    return wrapped
end

--- kamare 的页尺寸接口页号有时从 0 起，查看器只认从 1 起；拿不到就不预热。
---@param client table
---@param chapter_id any
---@return table|nil
local function dimensions(client, chapter_id)
    if type(client.getFileDimensions) ~= "function" then return nil end
    local dims, code = client:getFileDimensions(chapter_id)
    if type(dims) ~= "table" or type(code) ~= "number" or code < 200 or code >= 300 then return nil end
    local zero_based = false
    for _idx, item in ipairs(dims) do
        if item.pageNumber == 0 then zero_based = true end
    end
    if zero_based then
        for _idx, item in ipairs(dims) do
            if type(item.pageNumber) == "number" then item.pageNumber = item.pageNumber + 1 end
        end
    end
    return dims
end

--- 官方 / 旧版 kamare 的查看器通道：02 A4 要求官方版（无 kamarecache）与增强版缺 `open` 时
--- 仍保住今天的在线看图，所以这条通道留在适配层；source.lua 里那份重复实现已删（12 号票）。
---@param opts table
---@return table|nil viewer, string|nil code, string|nil message
local function legacyOpen(opts)
    local Viewer = loadModule("kamareimageviewer")
    if not Viewer or type(Viewer.new) ~= "function" then return nil, "unsupported" end
    local entry = opts.entry or {}
    if (tonumber(entry.pages) or 0) <= 0 then return nil, "no_pages" end
    local client = loadModule("kavitaclient")
    if not client then return nil, "open_failed", _("打开漫画阅读器失败") end
    local ok, viewer, code, message = pcall(function()
        client.base_url, client.api_key, client.auth_method, client.bearer =
            opts.base_url, opts.api_key, "apiKey", nil
        if not client.device_id or client.device_id == "" then client.device_id = "moon-kavita" end
        local images = client:streamChapter(entry.chapterId)
        if type(images) ~= "table" then return nil, "open_failed", _("打开漫画阅读器失败") end
        local LuaSettings = require("luasettings")
        local spec = Viewer:new{
            images_list_data = images,
            images_list_nb = entry.pages,
            title = opts.title,
            fullscreen = true,
            metadata = {
                seriesName = opts.title,
                seriesId = entry.seriesId,
                libraryId = entry.libraryId,
                volumeId = entry.volumeId,
                chapterId = entry.chapterId,
                chapter = { id = entry.chapterId, volumeId = entry.volumeId, pages = entry.pages },
                startPage = opts.start_page,
                content_type = "chapter",
            },
            preloaded_dimensions = dimensions(client, entry.chapterId),
            kamare_settings = LuaSettings:open(require("datastorage"):getSettingsDir() .. "/kamare.lua"),
            on_close_callback = opts.on_close,
            on_next_chapter_callback = opts.on_next and function(next_id)
                require("ui/uimanager"):nextTick(function() opts.on_next(next_id) end)
            end or nil,
        }
        if spec._aborted then return nil, "viewer_running", _("漫画阅读器已在运行") end
        require("ui/uimanager"):show(spec)
        return spec
    end)
    if not ok then
        logger.warn("kavita.cache legacy open failed", viewer)
        return nil, "open_failed", _("打开漫画阅读器失败")
    end
    return viewer, code, message
end

--- 增强版是否接管打开：起始页 / 离线全归 kamare（journal + 缓存）。
--- 官方版或增强版缺 `open` 时退回 legacy 查看器，起始页要 moon 自己给。
---@return boolean
function Cache.enhancedOpen()
    local probe = Cache.probe()
    if not probe.ok or (probe.capabilities or {}).open ~= true then return false end
    local mod = loadModule("kamarecache")
    return mod ~= nil and type(mod.open) == "function"
end

--- 打开一卷：enhanced 有 open 交 kamare 判缓存 / 离线 / 起始页；否则退回 legacy 查看器。
---@param opts { base_url: string|nil, api_key: string|nil, entry: table, title: string,
---              start_page: integer|nil, on_close: function|nil, on_next: function|nil }
---@return table|nil viewer, string|nil code, string|nil message
function Cache.open(opts)
    opts = type(opts) == "table" and opts or {}
    local entry = opts.entry or {}
    local base_url = normBase(opts.base_url) or targetBase()
    local api_key = normKey(opts.api_key) or normKey(config().api_key)
    if not base_url then return nil, "unknown_server" end
    local probe = Cache.probe()
    local mod = probe.ok and loadModule("kamarecache") or nil
    local use_enhanced = Cache.enhancedOpen()
    local viewer, code, message
    if use_enhanced then
        ensureMirror(false, base_url, api_key)
        viewer, code, message = mod.open(wrapClose(opts, base_url, entry.chapterId))
    else
        local next_opts = {}
        for key, value in pairs(opts) do next_opts[key] = value end
        next_opts.base_url, next_opts.api_key = base_url, api_key
        viewer, code, message = legacyOpen(wrapClose(next_opts, base_url, entry.chapterId))
    end
    if viewer then
        active = { base_url = base_url, chapter_id = entry.chapterId }
    elseif code then
        logOnce("open|" .. tostring(entry.chapterId) .. "|" .. code,
            "cache open cid=" .. tostring(entry.chapterId) .. " code=" .. tostring(code))
    end
    return viewer, code, message
end

--- 让书架投影失效（手动刷新书架 / Registry.reload 都走这里）。
function Cache.resetShelf()
    shelves = {}
end

--- 「已缓存」的唯一口径：complete 或 stale（stale 与 complete 等价，03 A3）。
--- 同时接受两种形状：Cache.status 的章状态（state）与书架 index 的系列摘要（complete/stale）。
---@param status table|nil
---@return boolean
function Cache.isCached(status)
    if type(status) ~= "table" then return false end
    if status.state == "complete" or status.state == "stale" then return true end
    if status.state ~= nil then return false end
    return status.complete == true or status.stale == true
end

--- 只读：书架投影（series_ids / mark / cover），按服务器记忆；无 TTL。
---@return ShelfCacheProjection|nil
function Cache.shelf()
    local base_url = targetBase()
    if not base_url then return nil end
    if shelves[base_url] then return shelves[base_url] end
    local index = Cache.index()
    if not index then return nil end
    local projection = { series_ids = {}, mark = {}, cover = {} }
    local series = type(index.series) == "table" and index.series or {}
    for key, info in pairs(series) do
        if type(info) == "table" then
            local stable_id = tostring(info.seriesId or key)
            -- 只有 complete / stale 算「已缓存」；queued / downloading 只有 .part，离线打不开。
            if (tonumber(info.chapters) or 0) > 0 and Cache.isCached(info) then
                projection.series_ids[stable_id] = true
                projection.mark[stable_id] = true
            end
            local cover = info.coverPath
            if type(cover) == "string" and cover ~= "" and fileExists(cover) then
                projection.cover[stable_id] = cover
            end
        end
    end
    shelves[base_url] = projection
    return projection
end

--- 只读：缓存占用（设置页与「缓存占用」展示；确认框一律用 estimate）。
---@return table|nil, string|nil, string|nil
function Cache.summary()
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("summary")
    if not mod then return nil, code end
    ensureMirror(false)
    return fn(base_url)
end

--- 只读：所有服务器（含未关联）的合计占用；未配置服务器时用它算「清理全部」的预览。
---@return table|nil, string|nil, string|nil
function Cache.summaryAll()
    local mod, code, fn = capability("summary")
    if not mod then return nil, code end
    return fn(nil)
end

--- 只读：当前服务器的清理计划（每章 facts）。series_id 可选。
---@param series_id any|nil
---@return table[]|nil, string|nil, string|nil
function Cache.chapters(series_id)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("chapters")
    if not mod then return nil, code end
    ensureMirror(false)
    return fn(base_url, series_id)
end

--- 只读：已缓存章的状态（complete / stale / partial）。
---@param chapter_id any
---@return table|nil, string|nil, string|nil
function Cache.status(chapter_id)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("status")
    if not mod then return nil, code end
    ensureMirror(false)
    return fn(base_url, chapter_id)
end

--- 只读：续读页（journal > snapshot > nil）。
---@param chapter_id any
---@param series_id any|nil
---@return table|nil, string|nil, string|nil
function Cache.resumePage(chapter_id, series_id)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("resume")
    if not mod then return nil, code end
    ensureMirror(false)
    return fn(base_url, chapter_id, series_id)
end

--- 只读：按当前服务器过滤后的队列状态。
---@return table|nil, string|nil, string|nil
function Cache.queueState()
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("queue")
    if not mod then return nil, code end
    ensureMirror(false)
    local state, err, message = fn(base_url)
    if type(state) == "table" then
        -- 1 秒轮询：只在暂停原因变化时记一行，恢复后清空，下次同原因再记。
        if state.pause_reason ~= nil and state.pause_reason ~= "" then
            if pause_reason_logged[base_url] ~= state.pause_reason then
                pause_reason_logged[base_url] = state.pause_reason
                logger.info("queue paused reason=" .. tostring(state.pause_reason))
            end
        else
            pause_reason_logged[base_url] = nil
        end
    end
    return state, err, message
end

--- 批量暂停（全局队列，契约明确作用于所有服务器）。
---@return boolean|nil, string|nil, string|nil
function Cache.queuePause()
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = queueControl("queue_pause")
    if not mod then return nil, code end
    ensureMirror(true)
    local ok, err, message = fn(base_url)
    logWrite("queue_pause", nil, err)
    if ok then Cache.resetShelf() end
    return ok, err, message
end

--- 批量恢复。
---@return boolean|nil, string|nil, string|nil
function Cache.queueResume()
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = queueControl("queue_resume")
    if not mod then return nil, code end
    ensureMirror(true)
    local ok, err, message = fn(base_url)
    logWrite("queue_resume", nil, err)
    if ok then Cache.resetShelf() end
    return ok, err, message
end

--- 只重试 queued / failed 的条目。
---@param chapter_ids any[]
---@return boolean|nil, string|nil, string|nil
function Cache.queueRetry(chapter_ids)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = queueControl("queue_retry")
    if not mod then return nil, code end
    ensureMirror(true)
    local ok, err, message = fn(base_url, chapter_ids)
    logWrite("queue_retry", chapter_ids, err)
    if ok then Cache.resetShelf() end
    return ok, err, message
end

--- 只读：书架索引投影（一次全量，不分页）。
---@return table|nil, string|nil, string|nil
function Cache.index()
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("index")
    if not mod then return nil, code end
    ensureMirror(false)
    return fn(base_url)
end

--- 写：入队下载。成功时第三个返回值是 { chapters, bytes, available }。
---@param entries table[]
---@return boolean|nil, string|nil, any, table|nil
function Cache.enqueue(entries)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("enqueue")
    if not mod then return nil, code end
    ensureMirror(true)
    local ok, err, message, detail = fn(base_url, entries)
    logWrite("enqueue", entryIds(entries), err)
    if ok then Cache.resetShelf() end
    return ok, err, message, detail
end

--- 写：删除缓存（不碰 journal）。正在查看器里打开的章本地先拦一次（与 kamare 双层保护）。
---@param chapter_ids any[]
---@return boolean|nil, string|nil, string|nil, integer|nil
function Cache.delete(chapter_ids)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    if active and active.base_url == base_url and includes(chapter_ids, active.chapter_id) then
        return nil, "chapter_open"
    end
    local mod, code, fn = capability("delete")
    if not mod then return nil, code end
    ensureMirror(true)
    local ok, err, message, deleted = fn(base_url, chapter_ids)
    logWrite("delete", chapter_ids, err)
    if ok then Cache.resetShelf() end
    return ok, err, message, deleted
end

--- 写：清空所有服务器（含未关联）。成功时第四个返回值是 { chapters, bytes } 估算。
---@return boolean|nil, string|nil, string|nil, table|nil
function Cache.deleteAll()
    local mod, code, fn = capability("delete_all")
    if not mod then return nil, code end
    local ok, err, third = fn()
    logWrite("delete_all", nil, err)
    if ok then
        Cache.resetShelf()
        return true, nil, nil, type(third) == "table" and third or nil
    end
    return nil, err, third
end

--- 只读：下载前估算（数量 / 峰值 / 可用 / 裁决），不写盘、不入队、不建 serverKey。
---@param entries table[]
---@return table|nil, string|nil, string|nil, table|nil
function Cache.estimate(entries)
    local base_url = targetBase()
    if not base_url then return nil, "unknown_server" end
    local mod, code, fn = capability("estimate")
    if not mod then return nil, code end
    ensureMirror(false)
    return fn(base_url, entries)
end

--- 错误码 → 用户可见文案（02 A9）。调用点只问这张表，不各写一套。
local SILENT = {
    unknown_server = true,
    already_cached = true,
    already_queued = true,
}

local CODE_TEXT = {
    offline_not_cached = _("这一卷还没缓存，联网后可下载"),
    viewer_running = _("漫画阅读器已在运行"),
    no_pages = _("这一卷没有可显示的页面"),
    settings_write_failed = _("无法写入 kamare 配置"),
    retry_no_entry = _("没有可重试的任务"),
    chapter_open = _("正在阅读这一卷，关闭后可以删除"),
    unsupported = _("需要安装带缓存接口的增强版 kamare"),
    base_url_required = _("无法同步配置到 kamare"),
    api_key_required = _("无法同步配置到 kamare"),
    delete_incomplete = _("部分缓存未能删除（权限或存储错误）"),
}

local SPACE_CODES = {
    not_enough_space = true,
    cache_limit_reached = true,
    low_space = true,
}

--- 字节数 → 一行「x.x MB」；不做单位阶梯，容量判断只看数量级。
---@param bytes any
---@return string
function Cache.sizeText(bytes)
    local value = tonumber(bytes)
    if not value then return _("未知") end
    return T(_("%1 MB"), string.format("%.1f", value / (1024 * 1024)))
end

--- 空间错误的 code + detail 文案。detail 由 kamare 给（不在 moon 复制阈值）。
---@param code string
---@param detail table|nil
---@return string
local function spaceText(code, detail)
    detail = type(detail) == "table" and detail or {}
    if code == "not_enough_space" then
        return T(_("空间不足：需要 %1，可用 %2"), Cache.sizeText(detail.needed), Cache.sizeText(detail.available))
    elseif code == "cache_limit_reached" then
        return T(_("缓存空间已满：需要 %1，上限 %2"), Cache.sizeText(detail.needed), Cache.sizeText(detail.limit))
    end
    return T(_("可用空间低于 %1，清理后再下载"), Cache.sizeText(detail.low_water))
end

--- code → 文案；静默码返回 nil。
---@param code string|nil
---@param message string|nil kamare 的原话（未知 code 时优先）
---@param detail table|nil 空间错误的 { needed, available, used, limit, low_water }
---@return string|nil
function Cache.message(code, message, detail)
    if code == nil or SILENT[code] then return nil end
    if SPACE_CODES[code] then return spaceText(code, detail) end
    return CODE_TEXT[code] or message or _("缓存操作失败")
end

--- 清理计划 → 汇总。`filter` 为 "read" 时只算已读；`toc_read` 是可选的服务端进度
--- （chapterId → pagesRead），用于补上 kamare 离线拿不到的第三源。
---@param entries table[]|nil
---@param filter "all"|"read"
---@param toc_read table<string, number>|nil
---@return { chapters: integer, bytes: integer, ids: any[], queued: integer, open: boolean }
function Cache.plan(entries, filter, toc_read)
    local out = { chapters = 0, bytes = 0, ids = {}, queued = 0, open = false }
    for _idx, entry in ipairs(type(entries) == "table" and entries or {}) do
        local pages = tonumber(entry.pages) or 0
        local server_read = toc_read and (tonumber(toc_read[tostring(entry.chapterId)]) or 0) or 0
        local read = entry.read == true or (pages > 0 and server_read >= pages)
        if filter ~= "read" or read then
            out.chapters = out.chapters + 1
            out.bytes = out.bytes + (tonumber(entry.bytes) or 0)
            out.ids[#out.ids + 1] = entry.chapterId
            if entry.queued then out.queued = out.queued + 1 end
            if entry.open then out.open = true end
        end
    end
    return out
end

--- estimate 的裁决 → 确认框 / toast 文案；可下载时 nil。
---@param result table|nil
---@return string|nil
function Cache.estimateMessage(result)
    if type(result) ~= "table" or result.ok then return nil end
    if result.reason == "nothing_to_do" then return _("全部已缓存或正在下载") end
    if result.reason == "space" then
        return T(_("空间不足：需要 %1，可用 %2"), Cache.sizeText(result.bytes), Cache.sizeText(result.available))
    end
    if result.reason == "low_water" then
        return T(_("可用空间不足（剩余 %1），清理后再下载"), Cache.sizeText(result.available))
    end
    return nil
end

--- 逐条 lastError 的特征 → 文案（07 A7）。moon 不加自动重试，只负责解释。
local FAILURE_PATTERNS = {
    { "http 403", _("服务器拒绝下载（403），检查 API Key / 权限") },
    { "not an archive", _("下载内容不完整或不是有效压缩包") },
    { "size ", _("下载内容不完整或不是有效压缩包") },
    { "extracted", _("下载内容不完整或不是有效压缩包") },
    { "sink write failed", _("存储空间不足或写入失败") },
    { "no space", _("存储空间不足或写入失败") },
    { "disk full", _("存储空间不足或写入失败") },
    { "socket", _("网络中断或服务器不可达") },
    { "connect", _("网络中断或服务器不可达") },
    { "closed", _("网络中断或服务器不可达") },
    { "truncated", _("网络中断或服务器不可达") },
    { "timeout", _("网络中断或服务器不可达") },
}

---@param last_error string|nil
---@return string|nil
function Cache.failureText(last_error)
    if type(last_error) ~= "string" or last_error == "" then return nil end
    local lowered = last_error:lower()
    for _idx, pattern in ipairs(FAILURE_PATTERNS) do
        if lowered:find(pattern[1], 1, true) then return pattern[2] end
    end
    return T(_("缓存失败：%1"), last_error)
end

return Cache
