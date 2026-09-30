--[[--
字体目录：可选字体列表与微信读书字体下载。

列表顺序：微信读书 → 设置目录 fonts → 系统。
扫描走 Job 子进程；微信列表走 Request.get 的 http.Cache（持久化，TTL 内不联网）。

@module koplugin.book.ui.fonts.catalog
--]]

local Archiver = require("ffi/archiver")
local FontList = require("fontlist")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local util = require("util")
local Request = require("http.request")
local Paths = require("utils.paths")
local Job = require("workers.job")
local Text = require("utils.text")
local Fonts = require("ui.fonts")
local _ = require("gettext")

local Catalog = {}

local LIST_URL = "https://weread.qq.com/feconfig/font/list?type=web_v2"
local LIST_TTL = 7 * 24 * 3600 -- 7 天

--- 本地可选扩展名（不含 woff：微信下载落在 .moon/fonts）
local LOCAL_EXT = { ttf = true, ttc = true, cff = true, otf = true }

--- 本地扫描结果，一个会话只扫一次：扫描要起子进程，子进程里加载的 FontList 回不到主进程，
--- 每次重扫就是每次都卡。KOReader 的 FontList 本身也是会话级的，新放入的字体重启后出现。
---@type { settings: MoonFontItem[], system: MoonFontItem[] }|nil
local scanned

---@class MoonFontItem
---@field id string 写入 ui_font
---@field name string
---@field kind string "local"|"weread"|"system"
---@field url string|nil
---@field preview string|nil
---@field zip_size number|nil

--- 微信读书字体是否已下载（含旧版 .woff）。本地 / 系统字体来自扫描，不经这里。
---@param item MoonFontItem
---@return boolean
function Catalog.isInstalled(item)
    return Fonts.downloadedPath(item.id) ~= nil
end

local function byName(a, b) return (a.name or "") < (b.name or "") end

--- 扩展名可选且 basename 未出现过时追加一项；返回是否追加。
---@param out MoonFontItem[]
---@param seen table<string, boolean> 按 basename 去重
---@return boolean
local function addFont(out, seen, file, kind)
    local ext = file:lower():match("%.([^.]+)$") or ""
    if not LOCAL_EXT[ext] or seen[file] then return false end
    seen[file] = true
    out[#out + 1] = { id = file, name = file:gsub("%.[^%.]+$", ""), kind = kind }
    return true
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
        if file:sub(1, 1) ~= "." and addFont(out, seen, file, kind) then
            seen_paths[path] = true
        end
    end)
    table.sort(out, byName)
    return out
end

--- FontList 中尚未登记的路径 → 系统字库。
---@param seen table<string, boolean>
---@param seen_paths table<string, boolean>
---@return MoonFontItem[]
local function scanSystemFonts(seen, seen_paths)
    local out = {}
    FontList:getFontList()
    for _idx, path in ipairs(FontList.fontlist or {}) do
        if not seen_paths[path] then
            addFont(out, seen, Text.basename(path), "system")
        end
    end
    table.sort(out, byName)
    return out
end

--- 设置目录 + 系统字库（在 listAsync 的子进程里跑）。
---@return MoonFontItem[], MoonFontItem[]
local function scanInstalledFonts()
    local seen, seen_paths = {}, {}
    local settings = scanDirFonts(Fonts.settingsFontsDir(), "local", seen, seen_paths)
    local system = scanSystemFonts(seen, seen_paths)
    return settings, system
end

---@param raw_items table
---@return MoonFontItem[]
local function normalizeWeread(raw_items)
    local out = {}
    for _idx, it in ipairs(raw_items) do
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
    table.sort(out, byName)
    return out
end

--- 微信读书字体列表。http.Cache 只存 HTTP 200：强制门户等返回的 200 非 JSON 也会被缓存，
--- 解析失败时必须清掉，否则整个 TTL 内都拿不到列表。
---@param cb fun(items: MoonFontItem[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchWereadAsync(cb)
    return Request.get(LIST_URL, { cache_ttl = LIST_TTL, accept = "application/json" }, function(body, err)
        if not body then
            cb(nil, err or _("获取字体列表失败"))
            return
        end
        local ok, data = pcall(JSON.decode, body)
        if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
            Request.clearCache(LIST_URL)
            cb(nil, _("字体列表解析失败"))
            return
        end
        cb(normalizeWeread(data.items))
    end)
end

--- 异步列表：本地扫描（子进程，会话内只跑一次）与微信列表并发，都到齐后合并回调一次。
--- 任一路的错误都带回给调用方，但列表仍按已有结果给出。
---@param cb fun(items: MoonFontItem[], err: string|nil)
---@return { cancel: fun() }
function Catalog.listAsync(cb)
    local cancelled = false
    local pending = scanned and 1 or 2
    local weread, weread_err, scan_err
    local settings, system
    if scanned then
        settings, system = scanned.settings, scanned.system
    end
    local function finish()
        pending = pending - 1
        if cancelled or pending > 0 then return end
        local out = {}
        for _idx, list in ipairs({ weread or {}, settings or {}, system or {} }) do
            for _idx, it in ipairs(list) do out[#out + 1] = it end
        end
        cb(out, weread_err or scan_err)
    end

    local scan_job = not scanned and Job.run(function()
        local s, sys = scanInstalledFonts()
        return { settings = s, system = sys }
    end, {
        name = "font.scan",
        kind = "medium",
        on_done = function(data)
            scanned = data
            settings, system = data.settings, data.system
            finish()
        end,
        on_failed = function(err)
            logger.warn("book.font scan failed", err)
            scan_err = err or _("字体扫描失败")
            finish()
        end,
    })
    local net_job = fetchWereadAsync(function(items, err)
        weread, weread_err = items, err
        finish()
    end)

    return { cancel = function()
            cancelled = true
            if scan_job then scan_job:cancel() end
            net_job.cancel()
        end }
end

--- 从下载的 zip 里抽出第一个 .woff/.woff2，转成 sfnt 落到 dest。
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
    local woff = dest:gsub("%.ttf$", ".woff")
    os.remove(dest)
    os.remove(woff)
    local extracted = arc:extractToPath(entry_path, woff)
    local extract_err = arc.err
    arc:close()
    os.remove(zip_path)
    if not extracted or not Fonts.isFile(woff) or not Fonts.finalizeWoff(woff, dest) then
        os.remove(woff)
        os.remove(dest)
        return nil, extract_err or _("字体解压失败")
    end
    return true
end

--- 确保字体可用：微信读书字体未下载时下载 zip 并在子进程解压；其余直接回调成功。
--- 下载前先删掉残留 zip，避免续用上次中断的半截包。
---@param item MoonFontItem
---@param on_progress fun(bytes: number)|nil 下载字节进度
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.ensureInstalledAsync(item, on_progress, cb)
    local noop = { cancel = function() end }
    if item.kind ~= "weread" or Fonts.downloadedPath(item.id) then
        cb(true)
        return noop
    end
    local dest = Fonts.wereadPath(item.id)
    if not dest then
        cb(nil, _("无效字体项"))
        return noop
    end
    Paths.ensureFonts()
    local zip_path = dest:gsub("%.ttf$", ".zip")
    local cancelled = false
    local extract_job
    os.remove(zip_path)
    local download_job = Request.download({
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
            kind = "heavy",
            on_done = function()
                if cancelled then return end
                if Fonts.isFile(dest) then
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
    return { cancel = function()
            cancelled = true
            download_job.cancel()
            if extract_job then extract_job:cancel() end
        end }
end

return Catalog
