--[[--
月读插件 UI 字体

  set(id, name)       只写 display.ui_font / ui_font_name，绝不碰 Font.fontmap
  applyCurrent()      唯一改 Font.fontmap 的入口；由 Desktop / Reader 在重建时调用
  listAsync / ensureInstalledAsync / isInstalled  列表与下载

字源：
  id == ""                         恢复首次备份的 fontmap（配置空值；选择器不提供此项）
  .moon/fonts/<id>.woff            微信读书已下载
  $DATA/fonts/<basename>           KOReader 设置目录字库
  FontList 其余路径                 系统字库（basename == id）

列表顺序：微信读书 → 设置目录 fonts → 系统。
扫描走 Job 子进程；微信列表 http.Cache（TTL）优先，磁盘 list.json 作冷启动备份。

@module koplugin.book.moon.font
--]]

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local FontList = require("fontlist")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local util = require("util")
local Cache = require("http.cache")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Job = require("workers.job")
local Text = require("utils.text")
local _ = require("gettext")

local MoonFont = {}

local LIST_URL = "https://weread.qq.com/feconfig/font/list?type=web_v2"
local LIST_TTL = 7 * 24 * 3600 -- 7 天
local LIST_CACHE_KEY = Cache.key("GET", LIST_URL)

--- 本地可选扩展名（不含 woff：微信下载落在 .moon/fonts）
local LOCAL_EXT = { ttf = true, ttc = true, cff = true, otf = true }

local UI_FACES = {
    "cfont", "tfont", "smalltfont", "x_smalltfont",
    "ffont", "smallffont", "largeffont",
    "rifont", "pgfont", "hfont",
    "infofont", "smallinfofont", "smallinfofontbold",
    "x_smallinfofont", "xx_smallinfofont",
}

local _defaults = nil
local _weread_cache = nil

---@class MoonFontItem
---@field id string 写入 ui_font；空=恢复默认 fontmap
---@field name string
---@field kind string "local"|"weread"|"system"
---@field url string|nil
---@field preview string|nil
---@field zip_size number|nil
---@field path string|nil

--- 首次调用时备份 Font.fontmap 里 UI 各 face 的原始值。
--- 只备份一次：这份快照是「恢复系统默认」的唯一依据，被后续 apply 覆盖过就找不回来了。
local function saveFontmapDefaults()
    if _defaults then return end
    _defaults = {}
    for _, key in ipairs(UI_FACES) do
        _defaults[key] = Font.fontmap[key]
    end
end

--- 把字体 id 规范成可安全拼进文件名的形式：去空白，非 [%w._-] 一律换成下划线。
---@param id string
---@return string
local function sanitizeId(id)
    return (Text.stripWhitespace(id):gsub("[^%w%._%-]", "_"))
end

--- 微信读书字体在 .moon/fonts 下的落盘路径。
---@param id string 字体 id（内部会 sanitize）
---@return string|nil nil 表示 id 规范化后为空
local function wereadPath(id)
    id = sanitizeId(id)
    if id == "" then return nil end
    return Paths.fontsDir() .. "/" .. id .. ".woff"
end

--- 取路径最后一段（同时兼容 / 与 \ 分隔）。
---@param path any 非字符串按 tostring 处理
---@return string
local function basename(path)
    return (tostring(path or ""):match("([^/\\]+)$")) or tostring(path or "")
end

--- 微信读书字体列表的磁盘备份路径（http.Cache 失效时的冷启动来源）。
---@return string
local function listCachePath()
    return Paths.fontsDir() .. "/list.json"
end

--- KOReader 设置目录 fonts（$DATA/fonts）
---@return string
local function settingsFontsDir()
    return DataStorage:getDataDir() .. "/fonts"
end

--- 当前配置的 UI 字体 id；空串表示用系统默认 fontmap。
---@return string
function MoonFont.currentId()
    return tostring(MoonSettings.get().ui_font or "")
end

--- 当前 UI 字体的显示名：优先用配置里记的中文名，退回 id，都没有显示「系统默认」。
---@return string
function MoonFont.currentName()
    local s = MoonSettings.get()
    if type(s.ui_font_name) == "string" and s.ui_font_name ~= "" then
        return s.ui_font_name
    end
    local id = tostring(s.ui_font or "")
    return id ~= "" and id or _("系统默认")
end

--- 字体是否已可用。
--- local / system 字源本来就在盘上，恒为 true；只有微信读书字体需要检查 .woff 是否落盘。
---@param id_or_item string|MoonFontItem 字体 id 或列表项
---@return boolean
function MoonFont.isInstalled(id_or_item)
    if type(id_or_item) == "table" then
        if id_or_item.kind == "local" or id_or_item.kind == "system" then return true end
        id_or_item = id_or_item.id
    end
    local path = wereadPath(id_or_item)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

--- 递归扫描目录内字体；seen 按 basename 去重。
---@param dir string
---@param kind string
---@param seen table<string, boolean>
---@param seen_paths table<string, boolean>
---@return MoonFontItem[]
local function scanDirFonts(dir, kind, seen, seen_paths)
    local out = {}
    if lfs.attributes(dir, "mode") ~= "directory" then
        return out
    end
    util.findFiles(dir, function(path, file)
        if file:sub(1, 1) == "." then return end
        local ext = file:lower():match("%.([^.]+)$") or ""
        if not LOCAL_EXT[ext] or seen[file] then return end
        seen[file] = true
        seen_paths[path] = true
        out[#out + 1] = {
            id = file,
            name = file:gsub("%.[^%.]+$", ""),
            kind = kind,
            path = path,
            zip_size = 0,
        }
    end)
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

--- FontList 中尚未登记的路径 → 系统字库。
---@param seen table<string, boolean>
---@param seen_paths table<string, boolean>
---@return MoonFontItem[]
local function scanSystemFonts(seen, seen_paths)
    local out = {}
    FontList:getFontList()
    for _, path in ipairs(FontList.fontlist or {}) do
        if not seen_paths[path] then
            local file = basename(path)
            if file ~= "" and not seen[file] then
                local ext = file:lower():match("%.([^.]+)$") or ""
                if LOCAL_EXT[ext] then
                    seen[file] = true
                    out[#out + 1] = {
                        id = file,
                        name = file:gsub("%.[^%.]+$", ""),
                        kind = "system",
                        path = path,
                        zip_size = 0,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

--- 设置目录 + 系统字库（同步；listAsync 在子进程跑同一逻辑）。
---@return MoonFontItem[], MoonFontItem[]
local function scanInstalledFonts()
    local seen, seen_paths = {}, {}
    local settings = scanDirFonts(settingsFontsDir(), "local", seen, seen_paths)
    local system = scanSystemFonts(seen, seen_paths)
    return settings, system
end

---@param raw_items table|nil
---@return MoonFontItem[]
local function normalizeWeread(raw_items)
    local out = {}
    for _, it in ipairs(raw_items or {}) do
        if type(it) == "table" then
            local id, url = it.id or it.font, it.url
            if id and url then
                local preview = it.preview or it.previewImageUrl or it.preview_image_url
                out[#out + 1] = {
                    id = tostring(id),
                    name = tostring(it.name or it.fontName or id),
                    kind = "weread",
                    url = tostring(url),
                    preview = preview and tostring(preview) or nil,
                    zip_size = tonumber(it.zip_size or it.zipSize) or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

---@return MoonFontItem[]|nil
local function readDiskWeread()
    local f = io.open(listCachePath(), "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return nil end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        return nil
    end
    local fetched = tonumber(data.fetched_at) or 0
    if fetched > 0 and (os.time() - fetched) > LIST_TTL then
        return nil
    end
    return normalizeWeread(data.items)
end

---@param items MoonFontItem[]
local function writeDiskWeread(items)
    Paths.ensureFonts()
    local f = io.open(listCachePath(), "w")
    if not f then return end
    local ok, encoded = pcall(JSON.encode, { items = items, fetched_at = os.time() })
    if ok and type(encoded) == "string" then
        f:write(encoded)
    end
    f:close()
end

---@param weread MoonFontItem[]|nil
---@param settings MoonFontItem[]|nil
---@param system MoonFontItem[]|nil
---@return MoonFontItem[]
local function merge(weread, settings, system)
    local out = {}
    for _, it in ipairs(weread or {}) do out[#out + 1] = it end
    for _, it in ipairs(settings or {}) do out[#out + 1] = it end
    for _, it in ipairs(system or {}) do out[#out + 1] = it end
    return out
end

---@param items MoonFontItem[]
local function rememberWeread(items)
    _weread_cache = items
    writeDiskWeread(items)
    Cache.set(LIST_CACHE_KEY, { items = items }, LIST_TTL)
end

--- 同步列表：微信 + 设置目录 + 系统（不联网）。
---@return MoonFontItem[]
function MoonFont.list()
    if not _weread_cache then
        _weread_cache = readDiskWeread()
    end
    local settings, system = scanInstalledFonts()
    return merge(_weread_cache, settings, system)
end

--- 异步列表。扫描在子进程；微信 force=false：内存 → http.Cache → 磁盘 → 联网。
---@param force boolean|nil
---@param cb fun(items: MoonFontItem[], err: string|nil)
---@return { cancel: fun() }
function MoonFont.listAsync(force, cb)
    local cancelled = false
    local net_job, cache_job, scan_job
    local weread_result, settings_result, system_result
    local weread_done, scan_done = false, false
    local weread_err
    local scan_err

    --- 微信列表与本地扫描都到齐后合并回调一次（两路并发，谁后到谁触发）。
    --- 任一路的错误都带回给调用方，但列表仍按已有结果给出。
    local function try_finish()
        if cancelled or not weread_done or not scan_done then return end
        cb(merge(weread_result, settings_result, system_result), weread_err or scan_err)
    end

    --- 记下微信读书那一路的结果，并尝试收尾。
    ---@param weread MoonFontItem[]|nil 失败时可能是缓存兜底结果
    ---@param err string|nil
    local function finishWeread(weread, err)
        if cancelled then return end
        weread_result = weread
        weread_err = err
        weread_done = true
        try_finish()
    end

    scan_job = Job.run(function()
        local settings, system = scanInstalledFonts()
        return { settings = settings, system = system }
    end, {
        name = "font.scan",
        on_done = function(data)
            if cancelled then return end
            local settings, system = {}, {}
            if type(data) == "table" then
                settings = data.settings or {}
                system = data.system or {}
            end
            settings_result = settings
            system_result = system
            scan_done = true
            try_finish()
        end,
        on_failed = function(err)
            if cancelled then return end
            logger.warn("book.font scan failed", err)
            settings_result, system_result = {}, {}
            scan_err = err or _("字体扫描失败")
            scan_done = true
            try_finish()
        end,
    })

    --- 联网拉微信读书字体列表；成功则写入内存/磁盘/http.Cache 三处。
    --- 请求失败或响应无法解析时退回已有缓存（可能为 nil），并把错误一起带回。
    local function fetchNet()
        net_job = Request.request({
            url = LIST_URL,
            method = "GET",
            headers = { ["Accept"] = "application/json" },
            timeout = 30,
        }, function(res, err)
            if cancelled then return end
            if err or not Request.ok(res and res.code) then
                local fallback = _weread_cache or readDiskWeread()
                finishWeread(fallback, err or _("获取字体列表失败"))
                return
            end
            local ok, data = pcall(JSON.decode, res.body or "")
            if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
                finishWeread(_weread_cache or readDiskWeread(), _("字体列表解析失败"))
                return
            end
            local weread = normalizeWeread(data.items)
            rememberWeread(weread)
            finishWeread(weread)
        end)
    end

    if force then
        fetchNet()
    elseif _weread_cache then
        finishWeread(_weread_cache)
    else
        cache_job = Cache.getAsync(LIST_CACHE_KEY, function(hit)
            if cancelled then return end
            if type(hit) == "table" and type(hit.items) == "table" then
                _weread_cache = normalizeWeread(hit.items)
                writeDiskWeread(_weread_cache)
                finishWeread(_weread_cache)
                return
            end
            local disk = readDiskWeread()
            if disk then
                _weread_cache = disk
                finishWeread(disk)
                return
            end
            fetchNet()
        end)
    end

    return {
        cancel = function()
            cancelled = true
            if scan_job then scan_job:abort() end
            if cache_job and cache_job.cancel then cache_job.cancel() end
            if net_job and net_job.cancel then net_job.cancel() end
        end,
    }
end

--- 把字体文件路径插到 FontList 队首，让 KOReader 能解析到它。
--- 已在列表里就不重复插；插队首是为了同名 basename 时优先命中本插件指定的文件。
---@param path string
local function registerFontPath(path)
    FontList:getFontList()
    for _, p in ipairs(FontList.fontlist) do
        if p == path then return end
    end
    table.insert(FontList.fontlist, 1, path)
end

--- 在目录树里按 basename 找字体文件。
---@param dir string
---@param id string
---@return string|nil
local function findInDir(dir, id)
    local found
    if lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end
    util.findFiles(dir, function(path, file)
        if not found and file == id then
            found = path
        end
    end)
    return found
end

--- 设置目录或 FontList 里按 basename 找字体。
---@param id string
---@return string|nil
local function findInstalledFont(id)
    local path = findInDir(settingsFontsDir(), id)
    if path then return path end
    FontList:getFontList()
    for _, p in ipairs(FontList.fontlist or {}) do
        if basename(p) == id then return p end
    end
    return nil
end

---@param path string
---@return table|nil
local function ensureFontInfo(path)
    FontList:getFontList()
    if FontList.fontinfo[path] then
        return FontList.fontinfo[path]
    end
    local dir = path:match("^(.*)/[^/]+$")
    if not dir then
        return nil
    end
    local mark = { cache_dirty = false }
    FontList:_readList(dir, mark)
    return FontList.fontinfo[path]
end

---@param id string|nil
---@return string|nil, string|nil
local function resolvePath(id)
    id = sanitizeId(id or "")
    if id == "" then
        return ""
    end
    local woff = wereadPath(id)
    if woff and lfs.attributes(woff, "mode") == "file" then
        registerFontPath(woff)
        return woff
    end
    local path = findInstalledFont(id)
    if path then
        registerFontPath(path)
        return path
    end
    return nil, _("字体文件不存在")
end

---@param id string|nil
---@return string|nil, string|nil
function MoonFont.faceForId(id)
    local path, err = resolvePath(id)
    if not path then
        return nil, err
    end
    if path == "" then
        return nil, _("字体文件不存在")
    end
    local info = ensureFontInfo(path)
    if not info or not info[1] or not info[1].name then
        return nil, _("应用字体失败")
    end
    local cre = require("document/credocument"):engineInit()
    local registered, register_err = pcall(cre.registerFont, path)
    logger.dbg(
        "book font register",
        "id=" .. tostring(id),
        "path=" .. path,
        "face=" .. info[1].name,
        "registered=" .. tostring(registered),
        "error=" .. tostring(register_err)
    )
    return info[1].name
end

---@param ui table|nil
---@return boolean
function MoonFont.supportsReader(ui)
    return ui and ui.font ~= nil and type(ui.document) == "table"
        and type(ui.document.setFontFace) == "function" or false
end

---@param ui table|nil
---@return string
function MoonFont.readerCurrentId(ui)
    if ui and ui.doc_settings then
        local id = ui.doc_settings:readSetting("book_reader_font_id")
        if type(id) == "string" and id ~= "" then
            return id
        end
    end
    return ""
end

--- KOReader ReaderFont:onSetFont 在 FontList 未命中或 font_face 已相同时静默 no-op；
--- 全书偏好必须落到 document，不能依赖该路径。
---@param ui table
---@param face string
---@return boolean
local function setReaderFontFace(ui, face)
    if type(face) ~= "string" or face == "" then
        return false
    end
    ui.font.font_face = face
    ui.document:setFontFace(face)
    ui.font:onSaveSettings()
    if ui.handleEvent then
        ui:handleEvent(require("ui/event"):new("UpdatePos"))
    end
    return true
end

--- 把已解析的 CRE 字体名写入当前文档与 sidecar（不写 books.reader_prefs）。
---@param ui table|nil
---@param face string
---@param id string|nil
---@param name string|nil
---@return boolean
function MoonFont.applyFaceToReader(ui, face, id, name)
    if not MoonFont.supportsReader(ui) or not setReaderFontFace(ui, face) then
        return false
    end
    id = sanitizeId(id or "")
    ui.doc_settings:saveSetting("book_reader_font_id", id)
    ui.doc_settings:saveSetting("book_reader_font_name", name or id)
    ui.doc_settings:flush()
    return true
end

---@param ui table|nil
---@param id string
---@param name string|nil
---@return boolean|nil, string|nil
function MoonFont.applyToReader(ui, id, name)
    if not MoonFont.supportsReader(ui) then
        return nil, _("当前文档不支持字体与排版调整")
    end
    local face, err = MoonFont.faceForId(id)
    if not face then
        logger.warn("book font apply resolve failed", "id=" .. tostring(id), "error=" .. tostring(err))
        return nil, err
    end
    if not MoonFont.applyFaceToReader(ui, face, id, name) then
        logger.warn("book font apply failed", "id=" .. tostring(id), "face=" .. face)
        return nil, _("应用字体失败")
    end
    logger.dbg(
        "book font applied",
        ui.document and ui.document.file or "",
        "id=" .. tostring(id),
        "face=" .. face
    )
    require("book.reader_prefs").captureAndSave(ui)
    require("ui/uimanager"):setDirty(ui.dialog, "ui")
    return true
end

---@param id string|nil
---@return boolean|nil, string|nil
local function apply(id)
    saveFontmapDefaults()
    id = sanitizeId(id or "")
    if id == "" then
        for key, val in pairs(_defaults) do
            Font.fontmap[key] = val
        end
        Font.faces = {}
        return true
    end
    local path, err = resolvePath(id)
    if not path then return nil, err end
    local base = basename(path)
    for _, key in ipairs(UI_FACES) do
        Font.fontmap[key] = base
    end
    Font.faces = {}
    return true
end

--- 把配置里的字体真正写进 Font.fontmap（唯一改 fontmap 的入口）。
--- 字体文件已不存在时退回系统默认，只记警告，不让 UI 因缺字体起不来。
---@return boolean|nil ok, string|nil err
function MoonFont.applyCurrent()
    local id = MoonFont.currentId()
    if id ~= "" and not resolvePath(id) then
        logger.warn("book.font missing, fallback default", id)
        id = ""
    end
    return apply(id)
end

--- 从下载的 zip 里抽出第一个 .woff/.woff2 落到 dest。
--- 无论成功失败都删掉 zip_path；失败时连 dest 一起删，不留半截字体文件。
--- 在 Job 子进程里执行（会阻塞地解压）。
---@param zip_path string
---@param dest string
---@return boolean|nil ok, string|nil err
local function extractInstalledFont(zip_path, dest)
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        os.remove(zip_path)
        return nil, arc.err or _("无法打开字体压缩包")
    end
    local entry_path
    for entry in arc:iterate() do
        if entry.mode == "file" and entry.path:lower():match("%.woff2?$") then
            entry_path = entry.path
            break
        end
    end
    if not entry_path then
        arc:close()
        os.remove(zip_path)
        return nil, _("压缩包内无字体文件")
    end
    os.remove(dest)
    local extracted = arc:extractToPath(entry_path, dest)
    local extract_err = arc.err
    arc:close()
    os.remove(zip_path)
    if not extracted or lfs.attributes(dest, "mode") ~= "file" then
        os.remove(dest)
        return nil, extract_err or _("字体解压失败")
    end
    return true
end

--- 算出安装一个字体项需要的落盘路径。
--- 三种结果：local/system 返回 ("", "")，表示无需安装；已装好的返回 (dest, nil)；
--- 需要下载的返回 (dest, zip_path)。
---@param item MoonFontItem
---@return string|nil dest 字体最终路径
---@return string|nil zip_path 待下载的压缩包路径；nil 表示不必下载
---@return string|nil err 字体项非法
local function installPaths(item)
    if type(item) ~= "table" or not item.id then
        return nil, nil, _("无效字体项")
    end
    if item.kind == "local" or item.kind == "system" then return "", "", nil end
    if not item.url then return nil, nil, _("无效字体项") end
    local id = sanitizeId(item.id)
    Paths.ensureFonts()
    local dest = wereadPath(id)
    if dest and lfs.attributes(dest, "mode") == "file" then
        return dest, nil, nil
    end
    return dest, Paths.fontsDir() .. "/" .. id .. ".zip", nil
end

--- 确保字体可用：需要时下载 zip 并在子进程解压，已装好或无需安装则直接回调成功。
--- 下载前先删掉残留 zip，避免续用上次中断的半截包。
---@param item MoonFontItem
---@param on_progress fun(bytes: number)|nil 下载字节进度
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function MoonFont.ensureInstalledAsync(item, on_progress, cb)
    local dest, zip_path, path_err = installPaths(item)
    if path_err then
        cb(nil, path_err)
        return { cancel = function() end }
    end
    if dest == "" or not zip_path then
        cb(true)
        return { cancel = function() end }
    end
    local cancelled = false
    local download_job, extract_job
    os.remove(zip_path)
    download_job = Request.download({
        url = item.url,
        method = "GET",
        timeout = 300,
        on_progress = on_progress,
    }, zip_path, function(ok, err)
        if cancelled then return end
        if not ok then
            cb(nil, err)
            return
        end
        extract_job = Job.run(function()
            extractInstalledFont(zip_path, dest)
        end, {
            name = "font.extract",
            on_done = function()
                if cancelled then return end
                if lfs.attributes(dest, "mode") == "file" then
                    logger.info("book.font installed", item.id, dest)
                    cb(true)
                else
                    cb(nil, _("字体解压失败"))
                end
            end,
            on_failed = function()
                if not cancelled then cb(nil, _("字体解压失败")) end
            end,
        })
    end)
    return {
        cancel = function()
            cancelled = true
            if download_job then download_job.cancel() end
            if extract_job then extract_job:abort() end
        end,
    }
end

---@param id string|nil 空=恢复默认 fontmap
---@param name string|nil
---@return boolean
function MoonFont.set(id, name)
    id = sanitizeId(id or "")
    local s = MoonSettings.get()
    s.ui_font = id
    s.ui_font_name = (id ~= "" and name) and tostring(name) or ""
    MoonSettings.save(s)
    logger.info("book.font set", id, s.ui_font_name)
    return true
end

return MoonFont
