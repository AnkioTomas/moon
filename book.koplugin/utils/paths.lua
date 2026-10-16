--[[--
Moon 目录布局（$DATA/.moon）

  .moon/
    book.sqlite3         结构化数据
    book.log             插件日志
    dictionary*.sqlite3  输入法词库
    cache/
      <source>/
        book/<slug>/     整本 book.* 或章节 N.html；slug 由 stable_id 派生
        image/           网络图片 / 封面
      image/             不属于特定源的网络图片
      online/            ankio.net 接口 JSON；必应 / 摸鱼日报图同目录
    settings/            <拥有者末段>.lua、<源 id>.lua；common.lua 等拆分前的旧分区只作迁移来源
    screensaver/         锁屏资源
    backups/
      patches/<feature>/ 核心补丁安装前的原始文件备份
    fonts/               UI 字体

ensure* 只负责建目录；路径函数只拼路径，没有副作用。

@module koplugin.book.utils.paths
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5

local P = {}

--- 递归创建目录（已存在则跳过）
---@param path string|nil
---@return boolean|nil ok, string|nil err 目录可用时为 true；创建失败返回 nil 与原因
function P.ensureDir(path)
    if not path or path == "" then
        return nil, "empty path"
    end
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    local parent = path:match("(.+)/[^/]+/?$")
    if parent then
        local ok, err = P.ensureDir(parent)
        if not ok then return nil, err end
    end
    return lfs.mkdir(path)
end

--- 源 id 用作目录名：只留安全字符；缺参直接失败（禁止猜活跃源）
---@param id string
---@return string
function P.sanitizeSourceId(id)
    if type(id) ~= "string" or id == "" then
        error("sanitizeSourceId: source_id required")
    end
    -- 非法字符一对一换成 _，长度不变，不可能变空
    return (id:gsub("[^%w%._%-]", "_"))
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

--- 路径是否位于插件自己的 .moon 数据目录。
---@param path string|nil
---@return boolean
function P.isMoonPath(path)
    if type(path) ~= "string" then
        return false
    end
    local root = P.root()
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- 锁屏资源目录：$DATA/.moon/screensaver
---@return string
function P.screensaverDir()
    return P.root() .. "/screensaver"
end

function P.ensureScreensaverDir()
    P.ensureDir(P.screensaverDir())
end

--- 某源的缓存目录：cache/<source>/
---@param id string
---@return string
function P.sourceCacheDir(id)
    return P.cacheDir() .. "/" .. P.sanitizeSourceId(id)
end

--- 正文 epub 根目录：cache/<source>/book/
---@param id string
---@return string
function P.bookDir(id)
    return P.sourceCacheDir(id) .. "/book"
end

--- 封面/网络图目录：cache/<source>/image/
---@param id string
---@return string
function P.imageDir(id)
    return P.sourceCacheDir(id) .. "/image"
end

--- stable_id → 文件系统安全的目录/文件名片段。
--- stable_id 本身可能含 / 等路径分隔符，不能直接当目录名用；
--- 目录已按 source 分段，这里只需保证同源内不同 stable_id 不冲突。
---@param stable_id string
---@return string
function P.slugFor(stable_id)
    -- 缺参直接失败：nil/空串会撞到一个固定 slug，多本书共用工作目录
    if type(stable_id) ~= "string" or stable_id == "" then
        error("slugFor: stable_id required")
    end
    return md5(stable_id) --[[@as string]]
end

--- 单书封面缓存：cache/<source>/image/<slug>.png
--- 扫描提取与刮削下载共用；文件存在即封面可用，不入库。
---@param stable_id string
---@param id string
---@return string
function P.coverPath(stable_id, id)
    return P.imageDir(id) .. "/" .. P.slugFor(stable_id) .. ".png"
end

--- 单书工作目录：cache/<source>/book/<slug>/
---@param stable_id string
---@param id string
---@return string
function P.bookWorkDir(stable_id, id)
    return P.bookDir(id) .. "/" .. P.slugFor(stable_id)
end

--- 单章 HTML 路径（在线按章阅读落盘）。
---@param stable_id string
---@param idx integer
---@param id string
---@return string
function P.chapterPath(stable_id, idx, id)
    return P.bookWorkDir(stable_id, id) .. "/" .. idx .. ".html"
end

--- 章节的双语版：与原章同目录（相对图片路径照样有效），tag 为 `<engine>-<lang>`。
---@param path string 原章路径
---@param tag string
---@return string
function P.bilingualChapterPath(path, tag)
    return (path:gsub("%.html$", "")) .. ".bi-" .. tag .. ".html"
end

--- 双语章 → 原章；不是双语章原样返回。
---@param path string
---@return string
function P.chapterOrigin(path)
    return (path:gsub("%.bi%-[^/]+%.html$", ".html"))
end

--- 同一章的其它版本（原章与各双语章，存在的），不含 path 自己。
---@param path string
---@return string[]
function P.chapterVariants(path)
    local origin = P.chapterOrigin(path)
    local dir, idx = origin:match("^(.*)/(%d+)%.html$")
    local out = {}
    if not dir then return out end
    if origin ~= path and lfs.attributes(origin, "mode") == "file" then out[1] = origin end
    local pattern = "^" .. idx .. "%.bi%-.+%.html$"
    for name in lfs.dir(dir) do
        local file = dir .. "/" .. name
        if file ~= path and name:match(pattern) then out[#out + 1] = file end
    end
    return out
end

--- 插件 SQLite 路径：$DATA/.moon/book.sqlite3
---@return string
function P.dbPath()
    return P.root() .. "/book.sqlite3"
end

--- 插件独立日志：$DATA/.moon/book.log
---@return string
function P.logPath()
    return P.root() .. "/book.log"
end

--- 中文输入法词库路径；拼音用 dictionary.sqlite3，其余 dictionary-<id>.sqlite3。
---@param id "pinyin"|"wubi"|"cangjie"|"zhuyin"
---@return string
function P.imeDictPath(id)
    if id == "pinyin" then
        return P.root() .. "/dictionary.sqlite3"
    end
    if id ~= "wubi" and id ~= "cangjie" and id ~= "zhuyin" then
        error("imeDictPath: unsupported input method " .. tostring(id))
    end
    return P.root() .. "/dictionary-" .. id .. ".sqlite3"
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

--- 拥有者配置路径：settings/<section>.lua（section = 拥有者模块路径末段，或旧分区名）
---@param section string
---@return string
function P.sectionPath(section)
    return P.settingsDir() .. "/" .. section .. ".lua"
end

--- 源专用配置路径：settings/<id>.lua
---@param id string
---@return string
function P.sourcePath(id)
    return P.settingsDir() .. "/" .. id .. ".lua"
end

--- 保证 settings 目录存在。
function P.ensureSettings()
    P.ensureDir(P.settingsDir())
end

--- 某功能的补丁备份目录：$DATA/.moon/backups/patches/<feature>/
---@param feature string
---@return string
function P.patchBackupDir(feature)
    return P.root() .. "/backups/patches/" .. feature
end

--- 保证 fonts 目录存在
function P.ensureFonts()
    P.ensureDir(P.fontsDir())
end

--- 只保证共享缓存根存在；清理流程不能凭空猜测活跃 source_id。
function P.ensureCacheRoot()
    P.ensureDir(P.cacheDir())
end

--- ankio.net 接口缓存：cache/online/<name>.json
---@return string
function P.onlineCacheDir()
    return P.cacheDir() .. "/online"
end

function P.ensureOnlineCache()
    P.ensureDir(P.onlineCacheDir())
end

--- 通用网络图片目录（不属于特定源）：cache/image/
---@return string
function P.imageRootDir()
    return P.cacheDir() .. "/image"
end

--- 确保通用网络图片目录存在。
function P.ensureImageRoot()
    P.ensureDir(P.imageRootDir())
end

--- 确保指定源的 cache/<source>/book 与 image 目录存在
---@param id string
function P.ensureLayout(id)
    P.ensureDir(P.bookDir(id))
    P.ensureDir(P.imageDir(id))
end

--- 确保某书的工作目录存在：cache/<source>/book/<slug>/。
--- slug 是 md5(stable_id)，阅读时通过 books 表反查，不落额外身份文件。
---@param stable_id string
---@param id string
function P.ensureBookWork(stable_id, id)
    P.ensureLayout(id)
    P.ensureDir(P.bookWorkDir(stable_id, id))
end

return P
