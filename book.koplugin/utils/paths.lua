--[[--
Moon 目录布局（$DATA/.moon）

  .moon/
    book.sqlite3         结构化数据（books/tocs/opens/http）
    cache/
      <source>/
        book/<bookKey>/  整本 book.epub 或章节 N.epub
        image/           网络图片 / 封面
    settings/
      common.lua
      moon.lua / wechat.lua / webdav.lua
    fonts/               UI 字体（.woff）

注意：打开 settings 只能 ensureSettings，禁止 ensureLayout（会与 settings 读活跃源形成环）。

@module koplugin.book.moon.paths
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local P = {}

local KIND_BOOK = "book"
local KIND_IMAGE = "image"

--- 递归创建目录（已存在则跳过）
local function ensureDir(path)
    if not path or path == "" then
        return
    end
    if lfs.attributes(path, "mode") == "directory" then
        return
    end
    local parent = path:match("(.+)/[^/]+/?$")
    if parent and parent ~= "" and parent ~= path then
        ensureDir(parent)
    end
    lfs.mkdir(path)
end

--- 惰性取活跃源，避免与 moon.settings 顶层循环依赖
local function activeSourceId()
    local ok, Settings = pcall(require, "moon.settings")
    if ok and Settings and Settings.activeSourceId then
        local id = Settings.activeSourceId()
        if id and id ~= "" then
            return tostring(id)
        end
    end
    return "moon"
end

--- 源 id 用作目录名：只留安全字符
-- @param id string|nil
-- @return string
function P.sanitizeSourceId(id)
    id = tostring(id or activeSourceId())
    id = id:gsub("[^%w%._%-]", "_")
    if id == "" then
        id = "moon"
    end
    return id
end

--- $DATA/.moon
---@return string
function P.root()
    return DataStorage:getDataDir() .. "/.moon"
end

--- 缓存根：$DATA/.moon/cache
---@return string
function P.cacheDir()
    return P.root() .. "/cache"
end

--- 某源的缓存目录：cache/<source>/
---@param id string|nil
---@return string
function P.sourceCacheDir(id)
    return P.cacheDir() .. "/" .. P.sanitizeSourceId(id)
end

--- 正文 epub 根目录：cache/<source>/book/
---@param id string|nil
---@return string
function P.bookDir(id)
    return P.sourceCacheDir(id) .. "/" .. KIND_BOOK
end

--- 封面/网络图目录：cache/<source>/image/
---@param id string|nil
---@return string
function P.imageDir(id)
    return P.sourceCacheDir(id) .. "/" .. KIND_IMAGE
end

--- 单书工作目录：cache/<source>/book/<bookKey>/
---@param book_key string|nil
---@param id string|nil
---@return string
function P.bookWorkDir(book_key, id)
    return P.bookDir(id) .. "/" .. tostring(book_key or "")
end

--- 插件 SQLite 路径：$DATA/.moon/book.sqlite3
---@return string
function P.dbPath()
    return P.root() .. "/book.sqlite3"
end

--- settings 目录
---@return string
function P.settingsDir()
    return P.root() .. "/settings"
end

--- UI 字体目录
---@return string
function P.fontsDir()
    return P.root() .. "/fonts"
end

--- 通用配置文件路径 common.lua
---@return string
function P.commonPath()
    return P.settingsDir() .. "/common.lua"
end

--- 源专用配置路径：settings/<id>.lua
---@param id string|nil
---@return string
function P.sourcePath(id)
    id = tostring(id or "moon")
    return P.settingsDir() .. "/" .. id .. ".lua"
end

--- 只保证 settings 树存在。打开配置文件必须走这里，不能调 ensureLayout。
function P.ensureSettings()
    ensureDir(P.root())
    ensureDir(P.settingsDir())
end

--- 保证 fonts 目录存在
function P.ensureFonts()
    ensureDir(P.root())
    ensureDir(P.fontsDir())
end

--- 确保 .moon 与指定源（默认当前活跃源）的 cache/book/image 目录存在
---@param id string|nil
function P.ensureLayout(id)
    P.ensureSettings()
    ensureDir(P.cacheDir())
    id = P.sanitizeSourceId(id)
    ensureDir(P.sourceCacheDir(id))
    ensureDir(P.bookDir(id))
    ensureDir(P.imageDir(id))
    logger.dbg("book.paths ensureLayout", id)
end

--- 确保某书的工作目录存在：cache/<source>/book/<bookKey>/
---@param book_key string
---@param id string|nil
function P.ensureBookWork(book_key, id)
    P.ensureLayout(id)
    ensureDir(P.bookWorkDir(book_key, id))
end

return P
