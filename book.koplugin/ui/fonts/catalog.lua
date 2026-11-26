--[[--
字体目录：本地字体扫描（用户 / 本地 / 系统）与在线字体（moon-store.ankio.net）分类浏览下载。

- `listLocalAsync(cb)`：只扫描本地字体（用户 = $DATA/fonts 根目录，本地 = 子目录，系统 = FontList 其余路径），零联网。
- `listOnlineAsync(cb, opts)`：从 moon-store 拉取在线字体目录（含分类与名称预览图），经 http.Cache 持久化 24 小时，失败回落旧缓存。
- `downloadToUserAsync(item, on_progress, cb)`：直接把在线 TTF 下载到 `$DATA/fonts/<filename>`（先落 `.dl`，子进程校验 SFNT 魔数并按需补齐空格后原子改名）。

@module koplugin.book.ui.fonts.catalog
--]]

local FontList = require("fontlist")
local JSON = require("json")
local logger = require("utils.log")
local Cache = require("http.cache")
local Request = require("http.request")
local Paths = require("utils.paths")
local Job = require("workers.job")
local Text = require("utils.text")
local Fonts = require("ui.fonts")
local Sfnt = require("ui.fonts.sfnt")
local _ = require("gettext")

local Catalog = {}

Catalog.BASE_URL = "https://moon-store.ankio.net"
Catalog.LIST_URL = Catalog.BASE_URL .. "/api/v1/store/fonts"
Catalog.LIST_TTL = 24 * 3600 -- 24 小时
Catalog.PAGE_SIZE = 100
Catalog.MAX_PAGES = 20

--- 在线字体固定分类（与 moon-store FontCategoryCatalog 对齐）。
Catalog.CATEGORIES = {
    { code = "song", name = _("宋体") },
    { code = "hei", name = _("黑体") },
    { code = "kai", name = _("楷体") },
    { code = "yuan", name = _("圆体") },
    { code = "other", name = _("其他") },
}

--- 本地可选扩展名；用户目录额外展示 woff / woff2（界面标明兼容性差）。
local LOCAL_EXT = { ttf = true, ttc = true, cff = true, otf = true }
local WOFF_EXT = { woff = true, woff2 = true }

--- 合法 SFNT / TrueType Collection 文件头魔数。
local SFNT_MAGIC = {
    ["\0\1\0\0"] = true, -- TrueType
    OTTO = true,         -- OpenType / CFF
    ["true"] = true,     -- Apple TrueType
    typ1 = true,         -- PostScript Type 1 SFNT
    ttcf = true,         -- TrueType Collection
}

--- 本地扫描结果（用户在前、本地在后）：扫描要起子进程，所以按设置目录 fonts 的修改时间缓存，
--- 目录没变就不重扫；用户新下载或删除字体后立刻失效重扫。
---@type MoonFontItem[]|nil
local scanned
---@type integer|nil
local scanned_mtime

local function fontsMtime()
    return require("libs/libkoreader-lfs").attributes(Fonts.settingsFontsDir(), "modification")
end

--- 下载或删除用户字体后调用，确保下次打开字体选择框立刻反映磁盘变更。
function Catalog.invalidateLocalScan()
    scanned = nil
    scanned_mtime = nil
end

---@class MoonFontItem
---@field id string 写入 ui_font（本地为 basename，在线为 uid）
---@field name string
---@field kind string "online"|"user"|"local"|"system"
---@field woff boolean|nil 用户目录下的 woff / woff2 字体（兼容性差提示）
---@field filename string|nil 在线字体的原始文件名
---@field url string|nil
---@field preview string|nil
---@field size number|nil
---@field size_label string|nil
---@field category string|nil
---@field category_name string|nil
---@field note string|nil

local function byName(a, b) return a.name < b.name end

---@param value any
---@return string|nil
local function absUrl(value)
    if type(value) ~= "string" or value == "" then return nil end
    if value:match("^https?://") then return value end
    if value:sub(1, 1) == "/" then return Catalog.BASE_URL .. value end
    return nil
end

---@param kind any
---@return boolean
local function isOnlineKind(kind)
    return kind == "online" or kind == "weread"
end

--- 计算在线字体下载到本地用户字体目录（$DATA/fonts）的安全文件名。
---@param item MoonFontItem|table
---@return string|nil
function Catalog.targetFilename(item)
    if type(item) ~= "table" then return nil end
    local raw = type(item.filename) == "string" and Text.trim(item.filename) or ""
    if raw ~= "" and not raw:find("[/\\]") and not raw:find("%.%.") and not raw:find("[%c%z]")
        and raw:sub(1, 1) ~= "." and LOCAL_EXT[raw:lower():match("%.([^.]+)$")] then
        return raw
    end
    local id = type(item.id) == "string" and Text.stripWhitespace(item.id):gsub("[^%w%._%-]", "_") or ""
    if id == "" then return nil end
    if LOCAL_EXT[id:lower():match("%.([^.]+)$")] then return id end
    return id .. ".ttf"
end

--- 在线字体对应的本地用户字体完整路径。
---@param item MoonFontItem|table
---@return string|nil
function Catalog.userFilePath(item)
    local name = Catalog.targetFilename(item)
    if not name then return nil end
    return Fonts.userFontPath(name)
end

--- 在线字体是否已经下载到本地用户字体目录。
---@param item MoonFontItem|table
---@return boolean
function Catalog.isDownloadedToUser(item)
    local path = Catalog.userFilePath(item)
    return path ~= nil and Fonts.isFile(path)
end

--- 字体登记的任一中文名。OpenType name ID：4 = 全名，1 = 族名（与 getLocalizedFontName 同序）。
---@param names table|nil fontinfo 的 names：语言 → { [name_id] = string }
---@return string|nil
local function chineseName(names)
    for _idx, lang in ipairs({ "zh-tw", "zh-hk", "zh-cn", "zh-sg" }) do
        local n = names and names[lang]
        if n and (n[4] or n[1]) then return n[4] or n[1] end
    end
end

--- 设置目录 fonts：根目录 = 用户 user，子目录 = 本地 local；FontList 其余路径 = 系统 system。
--- 按 basename 去重；显示名：界面语言的本地化名 → 中文界面退回任一中文名（只登记 zh-cn 的字体在 zh_TW 下
--- getLocalizedFontName 取不到）→ 字体族名 → 文件名。
---@return MoonFontItem[]
local function scanInstalledFonts()
    local seen, groups = {}, { user = {}, ["local"] = {}, system = {} }
    local zh = (_.current_lang or ""):match("^zh")
    local function add(path, kind)
        local file = Text.basename(path)
        local ext = file:lower():match("%.([^.]+)$")
        local is_woff = kind == "user" and WOFF_EXT[ext] == true
        if seen[file] or (not LOCAL_EXT[ext] and not is_woff) then return end
        seen[file] = true
        local info = FontList.fontinfo[path]
        info = info and info[1]
        -- 粗体/斜体是同族变体：阅读页按族名 setFontFace 只会落到常规体，列出来选了也不生效
        if info and (info.bold or info.italic) then return end
        local name = FontList:getLocalizedFontName(path, 0) or (zh and info and chineseName(info.names))
            or (info and info.name) or file:gsub("%.[^%.]+$", "")
        table.insert(groups[kind], { id = file, name = name, kind = kind, woff = is_woff or nil })
    end
    local root = Fonts.settingsFontsDir()
    local fontlist = FontList:getFontList()
    local n = #fontlist
    FontList:_readList(root, {})
    for i = n + 1, #fontlist do
        add(fontlist[i], fontlist[i]:match("^(.*)/") == root and "user" or "local")
    end
    for i = 1, n do
        add(fontlist[i], "system")
    end
    local out = {}
    for _idx, kind in ipairs({ "user", "local", "system" }) do
        table.sort(groups[kind], byName)
        for _i, it in ipairs(groups[kind]) do out[#out + 1] = it end
    end
    return out
end

--- 只扫描本地字体（用户 / 本地 / 系统），绝不触发网络请求。
---@param cb fun(items: MoonFontItem[], err: string|nil)
---@return { cancel: fun() }
function Catalog.listLocalAsync(cb)
    local mtime = fontsMtime()
    if scanned_mtime ~= mtime then scanned = nil end
    if scanned then
        cb(scanned, nil)
        return { cancel = function() end }
    end
    local cancelled = false
    local scan_job = Job.run(scanInstalledFonts, {
        name = "font.scan",
        kind = "medium",
        on_done = function(data)
            if cancelled then return end
            scanned, scanned_mtime = data or {}, mtime
            cb(scanned, nil)
        end,
        on_failed = function(e)
            if cancelled then return end
            logger.warn("book.font scan failed", e)
            cb({}, e or _("字体扫描失败"))
        end,
    })
    return { cancel = function()
        cancelled = true
        if scan_job then scan_job:cancel() end
    end }
end

--- 兼容入口：本地字体列表（不再混入在线字体）。
Catalog.listAsync = Catalog.listLocalAsync

--- 把 moon-store 字体接口的单页回包收成 MoonFontItem[]；解析失败返回 nil。
---@param raw any
---@return MoonFontItem[]|nil items
---@return integer|nil total
local function parseApiPage(raw)
    local value = raw
    if type(value) == "string" then
        local ok, data = pcall(JSON.decode, value)
        if not ok then return nil end
        value = data
    end
    if type(value) ~= "table" or type(value.data) ~= "table" then return nil end
    local out = {}
    for _idx, it in ipairs(value.data) do
        if type(it) == "table" then
            local id = it.uid
            local url = absUrl(it.download_url)
            if type(id) == "string" and id ~= "" and url then
                out[#out + 1] = {
                    id = id,
                    name = tostring(it.name or it.filename or id),
                    filename = type(it.filename) == "string" and it.filename ~= "" and it.filename or nil,
                    kind = "online",
                    url = url,
                    preview = absUrl(it.name_preview_url or it.preview_url),
                    size = tonumber(it.size_bytes),
                    size_label = type(it.size_label) == "string" and it.size_label ~= "" and it.size_label or nil,
                    category = type(it.category) == "string" and it.category ~= "" and it.category or "other",
                    category_name = type(it.category_name) == "string" and it.category_name ~= "" and it.category_name or nil,
                    note = type(it.note) == "string" and it.note ~= "" and it.note or nil,
                }
            end
        end
    end
    return out, tonumber(value.count)
end

--- 缓存里是已解析的 MoonFontItem[]；格式不符返回 nil。
---@param value any
---@return MoonFontItem[]|nil
local function parseCachedList(value)
    if type(value) ~= "table" then return nil end
    local first = value[1]
    if type(first) == "table" and first.id and isOnlineKind(first.kind) then
        return value
    end
    if next(value) == nil then
        return value
    end
    return nil
end

--- 按页拉取 moon-store 全部启用字体，合并排序后回调。
---@param done fun(items: MoonFontItem[]|nil, err: string|nil)
---@return { cancel: fun() }
local function requestAllPages(done)
    local cancelled = false
    local current_job
    local all, seen = {}, {}
    local page = 1

    local function fetchPage()
        if cancelled then return end
        local url = string.format("%s?page=%d&pageSize=%d", Catalog.LIST_URL, page, Catalog.PAGE_SIZE)
        current_job = Request.get(url, { accept = "application/json" }, function(body, err)
            if cancelled then return end
            if not body then return done(nil, err or _("获取字体列表失败")) end
            local items, total = parseApiPage(body)
            if not items then return done(nil, _("字体列表解析失败")) end
            for _idx, it in ipairs(items) do
                if not seen[it.id] then
                    seen[it.id] = true
                    all[#all + 1] = it
                end
            end
            local more = #items >= Catalog.PAGE_SIZE
                and (not total or #all < total)
                and page < Catalog.MAX_PAGES
            if more then
                page = page + 1
                fetchPage()
                return
            end
            table.sort(all, byName)
            done(all)
        end)
    end

    fetchPage()
    return { cancel = function()
        cancelled = true
        if current_job and current_job.cancel then current_job.cancel() end
    end }
end

--- 在线字体目录（moon-store.ankio.net）。有效缓存直接返回，不联网；失败时回落磁盘旧缓存。
---@param cb fun(items: MoonFontItem[]|nil, err: string|nil)
---@param opts { force?: boolean }|nil
---@return { cancel: fun() }
function Catalog.listOnlineAsync(cb, opts)
    local cache_key = Cache.key("GET", Catalog.LIST_URL)
    if opts and opts.force then Cache.forget(cache_key) end
    return Cache.fetch(cache_key, Catalog.LIST_TTL, requestAllPages, function(value, err)
        local items = parseCachedList(value)
        if items then return cb(items, nil) end
        if value ~= nil and err == nil then
            Cache.forget(cache_key)
            return cb(nil, _("字体列表解析失败"))
        end
        cb(nil, err or _("获取字体列表失败"))
    end, { stale_on_error = true })
end

--- 校验下载下来的字体文件魔数、按需补齐空格字形，并原子移动到 dest；返回失败原因（nil 为成功）。
--- 无论成功失败都不保留 dl_path。在 Job 子进程里执行。
---@param dl_path string
---@param dest string
---@return string|nil err
local function installDownloadedFont(dl_path, dest)
    local f = io.open(dl_path, "rb")
    local magic = f and f:read(4)
    if f then f:close() end
    if not magic or not SFNT_MAGIC[magic] then
        os.remove(dl_path)
        return "not a font: " .. string.format("%q", (magic or ""):gsub("%c", "?"))
    end
    local _changed, repair_err = Sfnt.ensureSpace(dl_path)
    if repair_err then
        os.remove(dl_path)
        return repair_err
    end
    os.remove(dest)
    local renamed, rename_err = os.rename(dl_path, dest)
    if not renamed then
        os.remove(dl_path)
        return tostring(rename_err or "rename failed")
    end
    return nil
end

--- 下载在线字体到本地用户字体目录（$DATA/fonts/<filename>）。
--- 成功回调 cb(true, filename)；失败回调 cb(nil, err)。
---@param item MoonFontItem
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, detail: string|nil)
---@return { cancel: fun() }
function Catalog.downloadToUserAsync(item, on_progress, cb)
    local noop = { cancel = function() end }
    local filename = Catalog.targetFilename(item)
    local dest = filename and Fonts.userFontPath(filename)
    if not dest or type(item.url) ~= "string" or item.url == "" then
        cb(nil, _("无效字体项"))
        return noop
    end
    Paths.ensureDir(Fonts.settingsFontsDir())
    local dl_path = dest .. ".dl"
    local cancelled = false
    local install_job
    os.remove(dl_path)
    local host = item.url:match("^https?://([^/]+)")
    logger.info("book.font download start", item.id, item.name, "dest=" .. dest, "dl=" .. dl_path,
        "size=" .. tostring(item.size or ""), host and ("host=" .. host) or "host=")
    logger.flushSync()
    local download_job = Request.download({
        url = item.url,
        timeout = require("http.timeout").net(10),
        resume = true,
        allow_redirects = true,
        on_progress = on_progress,
    }, dl_path, function(ok, err)
        if cancelled then return end
        if not ok then
            logger.warn("book.font download failed", item.id, "dl=" .. dl_path, err)
            logger.flushSync()
            return cb(nil, err)
        end
        local dl_file = io.open(dl_path, "rb")
        local dl_bytes = dl_file and dl_file:seek("end")
        if dl_file then dl_file:close() end
        logger.info("book.font download done", item.id, "dl=" .. dl_path, "bytes=" .. tostring(dl_bytes or ""))
        logger.flushSync()
        local function done(install_err)
            if cancelled then return end
            if install_err or not Fonts.isFile(dest) then
                logger.warn("book.font install failed", item.id, dest, install_err)
                logger.flushSync()
                return cb(nil, _("字体安装失败"))
            end
            Catalog.invalidateLocalScan()
            logger.info("book.font installed", item.id, dest)
            logger.flushSync()
            cb(true, filename)
        end
        install_job = Job.run(function() return installDownloadedFont(dl_path, dest) end,
            { name = "font.install", kind = "medium", on_done = done, on_failed = done })
    end)
    return { cancel = function()
        cancelled = true
        download_job.cancel()
        if install_job then install_job:cancel() end
    end }
end

return Catalog
