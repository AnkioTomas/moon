--[[--
Moon 目录布局（$DATA/.moon）

  .moon/
    book.sqlite3         结构化数据（books/opens/http）
    cache/
      <source>/
        book/<slug>/     整本 book.* 或章节 N.html；slug 由 stable_id 派生
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
local md5 = require("ffi/sha2").md5

local P = {}

local KIND_BOOK = "book"
local KIND_IMAGE = "image"

--- 递归创建目录（已存在则跳过）
---@param path string|nil
---@return nil
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

--- 源 id 用作目录名：只留安全字符；缺参直接失败（禁止猜活跃源）
---@param id string
---@return string
function P.sanitizeSourceId(id)
    if type(id) ~= "string" or id == "" then
        error("sanitizeSourceId: source_id required")
    end
    id = id:gsub("[^%w%._%-]", "_")
    if id == "" then
        error("sanitizeSourceId: empty after sanitize")
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

--- stable_id → 文件系统安全的目录/文件名片段。
--- stable_id 本身可能含 / 等路径分隔符（webdav 远程路径），不能直接当目录名用；
--- 目录已按 source 分段，这里只需保证同源内不同 stable_id 不冲突。
---@param stable_id string
---@return string
function P.slugFor(stable_id)
    return md5(tostring(stable_id or ""))
end

--- 单书封面缓存：cache/<source>/image/<slug>.png
--- 扫描提取与刮削下载共用；文件存在即封面可用，不入库。
---@param stable_id string
---@param id string|nil
---@return string
function P.coverPath(stable_id, id)
    return P.imageDir(id) .. "/" .. P.slugFor(stable_id) .. ".png"
end

--- 单书工作目录：cache/<source>/book/<slug>/
---@param stable_id string
---@param id string|nil
---@return string
function P.bookWorkDir(stable_id, id)
    return P.bookDir(id) .. "/" .. P.slugFor(stable_id)
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
---@return nil
function P.ensureSettings()
    ensureDir(P.root())
    ensureDir(P.settingsDir())
end

--- 保证 fonts 目录存在
---@return nil
function P.ensureFonts()
    ensureDir(P.root())
    ensureDir(P.fontsDir())
end

--- 只保证共享缓存根存在；清理流程不能凭空猜测活跃 source_id。
---@return nil
function P.ensureCacheRoot()
    P.ensureSettings()
    ensureDir(P.cacheDir())
end

--- 确保 .moon 与指定源的 cache/book/image 目录存在
---@param id string|nil
---@return nil
function P.ensureLayout(id)
    P.ensureCacheRoot()
    id = P.sanitizeSourceId(id)
    ensureDir(P.sourceCacheDir(id))
    ensureDir(P.bookDir(id))
    ensureDir(P.imageDir(id))
end

--- 确保某书的工作目录存在：cache/<source>/book/<slug>/
---@param stable_id string
---@param id string|nil
---@return nil
function P.ensureBookWork(stable_id, id)
    P.ensureLayout(id)
    ensureDir(P.bookWorkDir(stable_id, id))
end

return P
