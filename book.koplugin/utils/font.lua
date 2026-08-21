--[[--
Book 插件 UI 字体

  set(id, name)       只写 display.ui_font / ui_font_name，绝不碰 Font.fontmap
  applyCurrent()      唯一改 Font.fontmap 的入口；由 Desktop / Reader 在重建时调用
  listAsync / ensureInstalledAsync / isInstalled  列表与下载

字源：
  id == ""                         恢复首次备份的 fontmap（配置空值；选择器不提供此项）
  .moon/fonts/<id>.woff            微信读书已下载
  FontList.fontdir（koreader/fonts）下 basename == id

微信列表：http.Cache（TTL）优先，磁盘 list.json 作冷启动备份。

@module koplugin.book.moon.font
--]]

local Archiver = require("ffi/archiver")
local Font = require("ui/font")
local FontList = require("fontlist")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local Cache = require("http.cache")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Task = require("utils.task")
local Text = require("utils.text")
local _ = require("gettext")

local M = {}

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
---@field kind string "local"|"weread"
---@field url string|nil
---@field preview string|nil
---@field zip_size number|nil
---@field path string|nil

local function saveFontmapDefaults()
    if _defaults then return end
    _defaults = {}
    for _, key in ipairs(UI_FACES) do
        _defaults[key] = Font.fontmap[key]
    end
end

local function sanitizeId(id)
    return (Text.stripWhitespace(id):gsub("[^%w%._%-]", "_"))
end

local function wereadPath(id)
    id = sanitizeId(id)
    if id == "" then return nil end
    return Paths.fontsDir() .. "/" .. id .. ".woff"
end

local function basename(path)
    return (tostring(path or ""):match("([^/\\]+)$")) or tostring(path or "")
end

local function listCachePath()
    return Paths.fontsDir() .. "/list.json"
end

--- koreader/fonts 根目录（FontList.fontdir，通常为 ./fonts）
---@return string
local function koFontsDir()
    return FontList.fontdir or "./fonts"
end

function M.currentId()
    return tostring(MoonSettings.get().ui_font or "")
end

function M.currentName()
    local s = MoonSettings.get()
    if type(s.ui_font_name) == "string" and s.ui_font_name ~= "" then
        return s.ui_font_name
    end
    local id = M.currentId()
    return id ~= "" and id or _("系统默认")
end

function M.isInstalled(id_or_item)
    if type(id_or_item) == "table" then
        if id_or_item.kind == "local" then return true end
        id_or_item = id_or_item.id
    end
    local path = wereadPath(id_or_item)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

--- 只扫 koreader/fonts（递归），不碰系统/外置字库。
---@return MoonFontItem[]
local function listLocal()
    local out, seen = {}, {}
    local dir = koFontsDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        return out
    end
    util.findFiles(dir, function(path, file)
        if file:sub(1, 1) == "." then return end
        local ext = file:lower():match("%.([^.]+)$") or ""
        if not LOCAL_EXT[ext] or seen[file] then return end
        seen[file] = true
        out[#out + 1] = {
            id = file,
            name = file:gsub("%.[^%.]+$", ""),
            kind = "local",
            path = path,
            zip_size = 0,
        }
    end)
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
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
---@param local_items MoonFontItem[]
---@return MoonFontItem[]
local function merge(local_items, weread)
    local out = {}
    for _, it in ipairs(local_items) do out[#out + 1] = it end
    for _, it in ipairs(weread or {}) do out[#out + 1] = it end
    return out
end

---@param items MoonFontItem[]
local function rememberWeread(items)
    _weread_cache = items
    writeDiskWeread(items)
    Cache.set(LIST_CACHE_KEY, { items = items }, LIST_TTL)
end

--- 同步列表：本地 + 已有缓存（不联网）。
---@return MoonFontItem[]
function M.list()
    if not _weread_cache then
        _weread_cache = readDiskWeread()
    end
    return merge(listLocal(), _weread_cache)
end

--- 异步列表。force=false：内存 → http.Cache → 磁盘 → 联网；force=true：强制联网。
---@param force boolean|nil
---@param cb fun(items: MoonFontItem[], err: string|nil)
---@return { cancel: fun() }
function M.listAsync(force, cb)
    local local_items = listLocal()
    local cancelled = false
    local net_job, cache_job

    local function finish(weread, err)
        if cancelled then return end
        cb(merge(local_items, weread), err)
    end

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
                finish(fallback, err or _("获取字体列表失败"))
                return
            end
            local ok, data = pcall(JSON.decode, res.body or "")
            if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
                finish(_weread_cache or readDiskWeread(), _("字体列表解析失败"))
                return
            end
            local weread = normalizeWeread(data.items)
            rememberWeread(weread)
            finish(weread)
        end)
    end

    if force then
        fetchNet()
    elseif _weread_cache then
        finish(_weread_cache)
    else
        cache_job = Cache.getAsync(LIST_CACHE_KEY, function(hit)
            if cancelled then return end
            if type(hit) == "table" and type(hit.items) == "table" then
                _weread_cache = normalizeWeread(hit.items)
                writeDiskWeread(_weread_cache)
                finish(_weread_cache)
                return
            end
            local disk = readDiskWeread()
            if disk then
                _weread_cache = disk
                finish(disk)
                return
            end
            fetchNet()
        end)
    end

    return {
        cancel = function()
            cancelled = true
            if cache_job and cache_job.cancel then cache_job.cancel() end
            if net_job and net_job.cancel then net_job.cancel() end
        end,
    }
end

local function registerFontPath(path)
    FontList:getFontList()
    for _, p in ipairs(FontList.fontlist) do
        if p == path then return end
    end
    table.insert(FontList.fontlist, 1, path)
end

--- 在 koreader/fonts 树里按 basename 找文件。
---@param id string
---@return string|nil
local function findKoFont(id)
    local found
    local dir = koFontsDir()
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

---@param id string|nil
---@return string|nil, string|nil
local function resolveBasename(id)
    id = sanitizeId(id or "")
    if id == "" then return "" end
    local woff = wereadPath(id)
    if woff and lfs.attributes(woff, "mode") == "file" then
        registerFontPath(woff)
        return basename(woff)
    end
    local path = findKoFont(id)
    if path then
        registerFontPath(path)
        return id
    end
    return nil, _("字体文件不存在")
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
    local base, err = resolveBasename(id)
    if not base then return nil, err end
    for _, key in ipairs(UI_FACES) do
        Font.fontmap[key] = base
    end
    Font.faces = {}
    return true
end

function M.applyCurrent()
    local id = M.currentId()
    if id ~= "" and not resolveBasename(id) then
        logger.warn("book.font missing, fallback default", id)
        id = ""
    end
    return apply(id)
end

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

local function installPaths(item)
    if type(item) ~= "table" or not item.id then
        return nil, nil, _("无效字体项")
    end
    if item.kind == "local" then return "", "", nil end
    if not item.url then return nil, nil, _("无效字体项") end
    local id = sanitizeId(item.id)
    Paths.ensureFonts()
    local dest = wereadPath(id)
    if dest and lfs.attributes(dest, "mode") == "file" then
        return dest, nil, nil
    end
    return dest, Paths.fontsDir() .. "/" .. id .. ".zip", nil
end

function M.ensureInstalledAsync(item, on_progress, cb)
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
    local download_job, extract_task
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
        extract_task = Task.run(function()
            extractInstalledFont(zip_path, dest)
        end, {
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
            if extract_task then extract_task:abort() end
        end,
    }
end

---@param id string|nil 空=恢复默认 fontmap
---@param name string|nil
---@return boolean
function M.set(id, name)
    id = sanitizeId(id or "")
    local s = MoonSettings.get()
    s.ui_font = id
    s.ui_font_name = (id ~= "" and name) and tostring(name) or ""
    MoonSettings.save(s)
    logger.info("book.font set", id, s.ui_font_name)
    return true
end

return M
