--[[--
Book 插件 UI 字体

职责拆开（不要混）：
  set(id, name)       只写 common.ui_font / ui_font_name，绝不碰 Font.fontmap
  applyCurrent()      唯一改 Font.fontmap 的入口；由 Desktop / Reader 在重建时调用
  list / listAsync / ensureInstalledAsync / isInstalled  列表与下载

字源：
  id == ""                         系统默认（恢复首次备份的 fontmap）
  .moon/fonts/<id>.woff 存在       微信读书已下载
  FontList 里 basename == id       KOReader fonts/（及外部字库路径）

配置：common.ui_font / ui_font_name
只改插件 UI 字族（UI_FACES），不动阅读正文字体。

@module koplugin.book.moon.font
--]]

local Archiver = require("ffi/archiver")
local Font = require("ui/font")
local FontList = require("fontlist")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Task = require("utils.task")
local _ = require("gettext")

local M = {}

local LIST_URL = "https://weread.qq.com/feconfig/font/list?type=web_v2"

--- 插件 UI 字族键；等宽面故意不动
local UI_FACES = {
    "cfont", "tfont", "smalltfont", "x_smalltfont",
    "ffont", "smallffont", "largeffont",
    "rifont", "pgfont", "hfont",
    "infofont", "smallinfofont", "smallinfofontbold",
    "x_smallinfofont", "xx_smallinfofont",
}

local _defaults = nil
local _weread_cache = nil

--- 字体选择项（本地 FontList / 微信读书列表）
---@class MoonFontItem
---@field id string 写入 ui_font；空=系统默认
---@field name string 展示名
---@field kind string "local"|"weread"
---@field url string|nil weread 下载地址
---@field preview string|nil weread SVG 预览 URL
---@field zip_size number|nil weread 压缩包字节
---@field path string|nil local 绝对路径

--- 首次备份 UI_FACES 对应的 Font.fontmap（只做一次）
---@return nil
local function saveFontmapDefaults()
    if _defaults then
        return
    end
    _defaults = {}
    for _, key in ipairs(UI_FACES) do
        _defaults[key] = Font.fontmap[key]
    end
end

--- 消毒字体 id（去空白，非法字符变 _）
---@param id string|nil
---@return string
local function sanitizeId(id)
    return tostring(id or ""):gsub("%s+", ""):gsub("[^%w%._%-]", "_")
end

--- 微信读书字体本地路径：.moon/fonts/<id>.woff
---@param id string|nil
---@return string|nil
local function wereadPath(id)
    id = sanitizeId(id)
    if id == "" then
        return nil
    end
    return Paths.fontsDir() .. "/" .. id .. ".woff"
end

--- 路径末段文件名
---@param path string|nil
---@return string
local function basename(path)
    return (tostring(path or ""):match("([^/\\]+)$")) or tostring(path or "")
end

--- 当前配置 id；空=系统默认
---@return string
function M.currentId()
    return tostring(MoonSettings.get().ui_font or "")
end

--- 当前字体展示名
---@return string
function M.currentName()
    local s = MoonSettings.get()
    if type(s.ui_font_name) == "string" and s.ui_font_name ~= "" then
        return s.ui_font_name
    end
    local id = M.currentId()
    return id ~= "" and id or _("系统默认")
end

--- 本地是否可用：local 恒 true；weread 看 .woff
---@param id_or_item string|MoonFontItem|nil
---@return boolean
function M.isInstalled(id_or_item)
    if type(id_or_item) == "table" then
        if id_or_item.kind == "local" then
            return true
        end
        id_or_item = id_or_item.id
    end
    local path = wereadPath(id_or_item)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

--- 是否已有 weread 磁盘列表缓存（不影响 local）
---@return boolean
function M.hasWereadCache()
    if _weread_cache then
        return true
    end
    local f = io.open(Paths.fontsDir() .. "/list.json", "r")
    if not f then
        return false
    end
    f:close()
    return true
end

--- KOReader FontList（fonts/ + 外部目录）→ MoonFontItem[]
---@return MoonFontItem[]
local function listLocal()
    local out = {}
    local seen = {}
    FontList:getFontList()
    for _, path in ipairs(FontList.fontlist or {}) do
        local base = basename(path)
        if base ~= "" and not seen[base] then
            -- 跳过已登记的微信读书 .woff（走 weread 项）
            if not base:lower():match("%.woff2?$") then
                seen[base] = true
                local name = base:gsub("%.[^%.]+$", "")
                table.insert(out, {
                    id = base,
                    name = name,
                    kind = "local",
                    path = path,
                    zip_size = 0,
                })
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return out
end

--- 微信字体列表磁盘缓存路径
---@return string
local function listCachePath()
    return Paths.fontsDir() .. "/list.json"
end

--- 微信原始列表项 → MoonFontItem[]
---@param raw_items table|nil
---@return MoonFontItem[]
local function normalizeWeread(raw_items)
    local out = {}
    for _, it in ipairs(raw_items or {}) do
        if type(it) == "table" then
            local id = it.id or it.font
            local url = it.url
            if id and url then
                local preview = it.preview or it.previewImageUrl or it.preview_image_url
                table.insert(out, {
                    id = tostring(id),
                    name = tostring(it.name or it.fontName or id),
                    kind = "weread",
                    url = tostring(url),
                    preview = preview and tostring(preview) or nil,
                    zip_size = tonumber(it.zip_size or it.zipSize) or 0,
                })
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return out
end

--- 读磁盘微信字体列表缓存
---@return MoonFontItem[]|nil
local function readWereadCache()
    local f = io.open(listCachePath(), "r")
    if not f then
        return nil
    end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then
        return nil
    end
    local ok, data = pcall(JSON.decode, raw)
    if ok and type(data) == "table" and type(data.items) == "table" then
        return normalizeWeread(data.items)
    end
    return nil
end

--- 写磁盘微信字体列表缓存
---@param items MoonFontItem[]
---@return nil
local function writeWereadCache(items)
    Paths.ensureFonts()
    local f = io.open(listCachePath(), "w")
    if not f then
        return
    end
    local ok, encoded = pcall(JSON.encode, { items = items })
    if ok and type(encoded) == "string" then
        f:write(encoded)
    end
    f:close()
end

--- 仅微信读书列表（不含 local）。force 参数忽略：同步路径禁止联网。
---@param _force boolean|nil
---@return MoonFontItem[]|nil, string|nil
local function listWeread(_force)
    if _weread_cache then
        return _weread_cache
    end
    local disk = readWereadCache()
    if disk then
        _weread_cache = disk
        return disk
    end
    return nil, _("无本地字体列表缓存")
end

--- 合并列表：local 在前，weread 在后。永远返回 table（至少含 local）。
--- 仅本地 + 磁盘缓存；联网刷新请用 listAsync(true, cb)。
---@param _force boolean|nil 忽略（兼容旧调用）
---@return MoonFontItem[], string|nil weread 错误（有 local 仍成功）
function M.list(_force)
    local out = listLocal()
    local weread, err = listWeread()
    if weread then
        for _, it in ipairs(weread) do
            table.insert(out, it)
        end
    end
    return out, err
end

--- Fetch the remote font catalogue through KOReader's nonblocking HTTP loop.
---@param force boolean|nil
---@param cb fun(items: MoonFontItem[], err: string|nil)
---@return { cancel: fun() }
function M.listAsync(force, cb)
    if not force then
        cb(M.list(false))
        return { cancel = function() end }
    end
    local local_items = listLocal()
    local disk = readWereadCache()
    return Request.request({
        url = LIST_URL,
        method = "GET",
        headers = { ["Accept"] = "application/json" },
        timeout = 30,
    }, function(res, err)
        local weread, list_err
        if err or not Request.ok(res and res.code) then
            weread = disk
            list_err = err or _("获取字体列表失败")
        else
            local ok, data = pcall(JSON.decode, res.body or "")
            if ok and type(data) == "table" and type(data.items) == "table" then
                _weread_cache = normalizeWeread(data.items)
                writeWereadCache(_weread_cache)
                weread = _weread_cache
            else
                weread = disk
                list_err = _("字体列表解析失败")
            end
        end
        for _, item in ipairs(weread or {}) do
            table.insert(local_items, item)
        end
        cb(local_items, list_err)
    end)
end

--- 将字体路径插入 FontList.fontlist 头部（已存在则跳过）
---@param path string
---@return nil
local function registerFontPath(path)
    FontList:getFontList()
    for _, p in ipairs(FontList.fontlist) do
        if p == path then
            return
        end
    end
    table.insert(FontList.fontlist, 1, path)
end

--- 解析 id → fontmap 用的 basename；失败返回 nil, err
---@param id string|nil
---@return string|nil, string|nil
local function resolveBasename(id)
    id = sanitizeId(id or "")
    if id == "" then
        return ""
    end
    local woff = wereadPath(id)
    if woff and lfs.attributes(woff, "mode") == "file" then
        registerFontPath(woff)
        return basename(woff)
    end
    FontList:getFontList()
    for _, path in ipairs(FontList.fontlist or {}) do
        if basename(path) == id then
            return id
        end
    end
    return nil, _("字体文件不存在")
end

--- 改 UI_FACES 的 Font.fontmap；清空 Font.faces。id 空=恢复默认。
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
        logger.dbg("book.font apply default")
        return true
    end
    local base, err = resolveBasename(id)
    if not base then
        return nil, err
    end
    for _, key in ipairs(UI_FACES) do
        Font.fontmap[key] = base
    end
    Font.faces = {}
    logger.info("book.font apply", id, base)
    return true
end

--- 按配置打 fontmap。缺文件则回退系统默认（不改写配置）。
--- 调用方：Desktop:rebuild / ReaderFloatMenu:rebuild / Host.attach
---@return boolean|nil, string|nil
function M.applyCurrent()
    local id = M.currentId()
    if id ~= "" then
        local base = resolveBasename(id)
        if not base then
            logger.warn("book.font missing, fallback default", id)
            id = ""
        end
    end
    return apply(id)
end

--- Extract one downloaded font archive.
---@param zip_path string
---@param dest string
---@return boolean|nil, string|nil
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

--- Validate an item and calculate its installation paths.
---@param item MoonFontItem
---@return string|nil, string|nil, string|nil
local function installPaths(item)
    if type(item) ~= "table" or not item.id then
        return nil, nil, _("无效字体项")
    end
    if item.kind == "local" then
        return "", "", nil
    end
    if not item.url then
        return nil, nil, _("无效字体项")
    end
    local id = sanitizeId(item.id)
    Paths.ensureFonts()
    local dest = wereadPath(id)
    if dest and lfs.attributes(dest, "mode") == "file" then
        return dest, nil, nil
    end
    return dest, Paths.fontsDir() .. "/" .. id .. ".zip", nil
end

--- Download and extract a font without doing network or archive work in UI callbacks.
---@param item MoonFontItem
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
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
    local download_job
    local extract_task
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
                if not cancelled then
                    cb(nil, _("字体解压失败"))
                end
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

--- 只写配置，不 apply。真正生效等 Desktop/Reader rebuild → applyCurrent。
---@param id string|nil 空=系统默认
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
