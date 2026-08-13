--[[--
Book 桌面 UI 字体（微信读书字库）

  列表：https://weread.qq.com/feconfig/font/list?type=web_v2
  文件：.moon/fonts/<id>.woff
  缓存：.moon/fonts/list.json
  配置：common.ui_font / ui_font_name

只改插件 UI 字族（Font.fontmap 中 UI_FACES），不动阅读正文字体。

公开 API：
  list(force)                         字体列表（内存 + 磁盘缓存）
  isInstalled(id)                     本地是否已有 .woff
  currentId() / currentName()         当前配置
  ensureInstalled(item, on_progress)  下载 zip → 解出 .woff
  set(id, name)                       写配置并应用到 fontmap
  applyCurrent()                      启动时按配置应用（缺文件回退默认）

ensureInstalled / list 项（MoonFontItem）：
  id        string     字体 id（作文件名；会 sanitize）
  url       string     zip 下载地址（ensureInstalled 必填）
  name      string     展示名（缺省用 id）
  zip_size  number     压缩包字节数（0=未知；UI 进度条用）

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

--- 插件 UI 字族键；等宽面（如 mono）不在此列，故意不动
local UI_FACES = {
    "cfont", "tfont", "smalltfont", "x_smalltfont",
    "ffont", "smallffont", "largeffont",
    "rifont", "pgfont", "hfont",
    "infofont", "smallinfofont", "smallinfofontbold",
    "x_smallinfofont", "xx_smallinfofont",
}

--- 首次 apply 前备份的系统 Font.fontmap 片段；用于 id="" 恢复默认
local _defaults = nil
--- list() 内存缓存（与 list.json 同形：MoonFontItem[]）
local _list_cache = nil

local function saveFontmapDefaults()
    if _defaults then
        return
    end
    _defaults = {}
    for _, key in ipairs(UI_FACES) do
        _defaults[key] = Font.fontmap[key]
    end
end

--- 去掉空白，非法字符改成 `_`，避免路径注入
local function sanitizeId(id)
    return tostring(id or ""):gsub("%s+", ""):gsub("[^%w%._%-]", "_")
end

---@param id string|nil
---@return string|nil 绝对路径；id 空则 nil
local function localPath(id)
    id = sanitizeId(id)
    if id == "" then
        return nil
    end
    return Paths.fontsDir() .. "/" .. id .. ".woff"
end

--- 本地是否已有对应 .woff
---@param id string|nil
---@return boolean
function M.isInstalled(id)
    local path = localPath(id)
    return path and lfs.attributes(path, "mode") == "file"
end

--- 当前字体 id；空字符串 = 系统默认
---@return string
function M.currentId()
    return tostring(MoonSettings.get().ui_font or "")
end

--- 设置页展示名：优先 ui_font_name，否则 id，再否则「系统默认」
---@return string
function M.currentName()
    local s = MoonSettings.get()
    if type(s.ui_font_name) == "string" and s.ui_font_name ~= "" then
        return s.ui_font_name
    end
    local id = M.currentId()
    return id ~= "" and id or _("系统默认")
end

local function listCachePath()
    return Paths.fontsDir() .. "/list.json"
end

---@class MoonFontItem
---@field id string
---@field name string
---@field url string
---@field zip_size number

--- 兼容 API 原始字段（font/fontName/zipSize）与已规范化缓存
---@param raw_items table|nil
---@return MoonFontItem[]
local function normalizeItems(raw_items)
    local out = {}
    for _, it in ipairs(raw_items or {}) do
        if type(it) == "table" then
            local id = it.id or it.font
            local url = it.url
            if id and url then
                table.insert(out, {
                    id = tostring(id),
                    name = tostring(it.name or it.fontName or id),
                    url = tostring(url),
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
local function readListCache()
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
        return normalizeItems(data.items)
    end
    return nil
end

---@param items MoonFontItem[]
local function writeListCache(items)
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

--- 拉取字体列表
---
--- force=false / nil：只读内存 → 磁盘；都没有则 nil, err（不联网）
--- force=true：联网刷新并写缓存；失败时若有磁盘缓存则降级返回缓存
---@param force boolean|nil
---@return MoonFontItem[]|nil, string|nil
function M.list(force)
    if not force and _list_cache then
        return _list_cache
    end
    local disk = readListCache()
    if not force then
        if disk then
            _list_cache = disk
            return disk
        end
        return nil, _("无本地字体列表缓存")
    end
    local raw, err = Request.get(LIST_URL, { accept = "application/json" })
    if not raw then
        if disk then
            _list_cache = disk
            return disk
        end
        return nil, err
    end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        return nil, _("字体列表解析失败")
    end
    _list_cache = normalizeItems(data.items)
    writeListCache(_list_cache)
    return _list_cache
end

--- 把 .woff 插到 FontList 最前，供 Font 解析 basename
---@param path string
local function registerFontPath(path)
    FontList:getFontList()
    for _, p in ipairs(FontList.fontlist) do
        if p == path then
            return
        end
    end
    table.insert(FontList.fontlist, 1, path)
end

--- 改 UI_FACES 对应 Font.fontmap；清空 Font.faces 强制重建
---@param id string|nil 空=恢复首次备份的默认
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
    local path = localPath(id)
    if not path or lfs.attributes(path, "mode") ~= "file" then
        return nil, _("字体文件不存在，请先下载")
    end
    registerFontPath(path)
    local basename = path:match("([^/]+)$") or path
    for _, key in ipairs(UI_FACES) do
        Font.fontmap[key] = basename
    end
    Font.faces = {}
    logger.info("book.font apply", id, basename)
    return true
end

--- 按 common.ui_font 应用；已配置但文件缺失则回退系统默认（不改写配置）
---@return boolean|nil, string|nil
function M.applyCurrent()
    local id = M.currentId()
    if id ~= "" and not M.isInstalled(id) then
        logger.warn("book.font missing file, fallback default", id)
        id = ""
    end
    return apply(id)
end

--- 确保本地有 .woff：已存在直接 true；否则下载 zip，取包内首个 .woff/.woff2 写到 dest
---@param item MoonFontItem 必填 id、url；name / zip_size 可选
---@param on_progress fun(bytes: number)|nil 已下载字节回调（交给 Download.toFile）
---@return boolean|nil, string|nil
function M.ensureInstalled(item, on_progress)
    if type(item) ~= "table" or not item.id or not item.url then
        return nil, _("无效字体项")
    end
    local id = sanitizeId(item.id)
    Paths.ensureFonts()
    local dest = localPath(id)
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

--- 写入 ui_font / ui_font_name 并 apply
---@param id string|nil 空=系统默认（同时清空 ui_font_name）
---@param name string|nil 展示名；仅 id 非空时写入
---@return boolean|nil, string|nil
function M.set(id, name)
    id = sanitizeId(id or "")
    local s = MoonSettings.get()
    s.ui_font = id
    s.ui_font_name = (id ~= "" and name) and tostring(name) or ""
    MoonSettings.save(s)
    return apply(id)
end

return M
