--[[--
Book 插件 UI 字体

职责拆开（不要混）：
  set(id, name)       只写 common.ui_font / ui_font_name，绝不碰 Font.fontmap
  applyCurrent()      唯一改 Font.fontmap 的入口；由 Desktop / Reader 在重建时调用
  list / ensureInstalled / isInstalled  列表与下载

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
local Download = require("http.download")
local Paths = require("moon.paths")
local MoonSettings = require("moon.settings")
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

---@class MoonFontItem
---@field id string 写入 ui_font；空=系统默认
---@field name string 展示名
---@field kind string "local"|"weread"
---@field url string|nil weread 下载地址
---@field preview string|nil weread SVG 预览 URL
---@field zip_size number|nil weread 压缩包字节
---@field path string|nil local 绝对路径

local function saveFontmapDefaults()
    if _defaults then
        return
    end
    _defaults = {}
    for _, key in ipairs(UI_FACES) do
        _defaults[key] = Font.fontmap[key]
    end
end

local function sanitizeId(id)
    return tostring(id or ""):gsub("%s+", ""):gsub("[^%w%._%-]", "_")
end

local function wereadPath(id)
    id = sanitizeId(id)
    if id == "" then
        return nil
    end
    return Paths.fontsDir() .. "/" .. id .. ".woff"
end

local function basename(path)
    return (tostring(path or ""):match("([^/\\]+)$")) or tostring(path or "")
end

--- 当前配置 id；空=系统默认
---@return string
function M.currentId()
    return tostring(MoonSettings.get().ui_font or "")
end

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

local function listCachePath()
    return Paths.fontsDir() .. "/list.json"
end

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

---@param items MoonFontItem[]
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

--- 仅微信读书列表（不含 local）
---@param force boolean|nil
---@return MoonFontItem[]|nil, string|nil
local function listWeread(force)
    if not force and _weread_cache then
        return _weread_cache
    end
    local disk = readWereadCache()
    if not force then
        if disk then
            _weread_cache = disk
            return disk
        end
        return nil, _("无本地字体列表缓存")
    end
    local raw, err = Request.get(LIST_URL, { accept = "application/json" })
    if not raw then
        if disk then
            _weread_cache = disk
            return disk
        end
        return nil, err
    end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        return nil, _("字体列表解析失败")
    end
    _weread_cache = normalizeWeread(data.items)
    writeWereadCache(_weread_cache)
    return _weread_cache
end

--- 合并列表：local 在前，weread 在后。永远返回 table（至少含 local）。
---@param force boolean|nil force=true 时联网刷新 weread
---@return MoonFontItem[], string|nil weread 错误（有 local 仍成功）
function M.list(force)
    local out = listLocal()
    local weread, err = listWeread(force)
    if weread then
        for _, it in ipairs(weread) do
            table.insert(out, it)
        end
    end
    return out, err
end

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

--- 下载 weread zip → .moon/fonts/<id>.woff。local 项直接 true。
---@param item MoonFontItem
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, string|nil
function M.ensureInstalled(item, on_progress)
    if type(item) ~= "table" or not item.id then
        return nil, _("无效字体项")
    end
    if item.kind == "local" then
        return true
    end
    if not item.url then
        return nil, _("无效字体项")
    end
    local id = sanitizeId(item.id)
    Paths.ensureFonts()
    local dest = wereadPath(id)
    if dest and lfs.attributes(dest, "mode") == "file" then
        return true
    end

    local zip_path = Paths.fontsDir() .. "/" .. id .. ".zip"
    os.remove(zip_path)
    local ok, err = Download.toFile(item.url, zip_path, { on_progress = on_progress })
    if not ok then
        return nil, err
    end

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
    logger.info("book.font installed", id, dest)
    return true
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
