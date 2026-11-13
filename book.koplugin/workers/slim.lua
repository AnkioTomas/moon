--[[--
fork 子进程瘦身：只丢掉确认安全的位图缓存，必要时对位图数据做 MADV_DONTNEED。

只在 Job 子进程、跑任务之前调用。不要在父进程调：会拆掉仍在显示的位图。
不做：exec、对整个 Lua 状态 collectgarbage、拆 CRE / 文档、碰 MAP_SHARED（framebuffer）。

插件位图缓存、KOReader ImageCache、DocCache 里的 tile 都是进程内副本；
释放它们只影响子进程的写时复制页。其它 DocCache 项（版面、KOPT 上下文等）不动。

@module koplugin.book.workers.slim
--]]

local ffi = require("ffi")
local logger = require("utils.log")

local Slim = {}

local MADV_DONTNEED = 4
local PAGE_FALLBACK = 4096
local declared = false

local function declare()
    if declared then return end
    declared = true
    pcall(ffi.cdef, "int madvise(void *addr, size_t length, int advice);")
    pcall(ffi.cdef, "long sysconf(int name);")
end

--- Linux _SC_PAGESIZE 是 30。读不到就按 4K，避免把相邻页算进去。
---@return integer
local function pageSize()
    declare()
    local ok, n = pcall(function()
        return tonumber(ffi.C.sysconf(30))
    end)
    if ok and n and n >= 4096 and n <= 65536 and n % 4096 == 0 then
        return n
    end
    return PAGE_FALLBACK
end

--- 只对完全落在缓冲内部的整页做 DONTNEED，避免伤到相邻 malloc 对象。
--- framebuffer 等 MAP_SHARED 映射不会走到这里：只对即将释放的 BlitBuffer.data 调用。
---@param data any
---@param size number|nil
function Slim.advisePrivate(data, size)
    if ffi.os ~= "Linux" or data == nil or not size or size <= 0 then return end
    declare()
    local ok_addr, addr = pcall(function()
        return tonumber(ffi.cast("uintptr_t", data))
    end)
    if not ok_addr or not addr or addr == 0 then return end
    local page = pageSize()
    local start = math.ceil(addr / page) * page
    local finish = math.floor((addr + size) / page) * page
    if finish <= start then return end
    pcall(ffi.C.madvise, ffi.cast("void *", start), finish - start, MADV_DONTNEED)
end

---@param bb table|nil
---@return number|nil
local function blitSize(bb)
    if not bb then return nil end
    local stride = tonumber(bb.stride)
    local height = tonumber(bb.h)
    if stride and height then return stride * height end
end

--- 先对内部整页 DONTNEED，再 free。不 munmap：BlitBuffer 走 malloc，framebuffer 是 MAP_SHARED。
---@param bb table|nil
function Slim.releaseBlit(bb)
    if not bb then return end
    local size = blitSize(bb)
    if size and bb.data ~= nil then
        Slim.advisePrivate(bb.data, size)
    end
    if bb.free then bb:free() end
end

---@return integer
function Slim.dropPluginBitmaps()
    local core = package.loaded["ui.themes.widgets.image.core"]
    if not core or type(core.releaseCachedBitmaps) ~= "function" then return 0 end
    local ok, n = pcall(core.releaseCachedBitmaps, Slim.releaseBlit)
    if not ok then
        logger.warn("book.worker slim bitmaps failed", n)
        return 0
    end
    return n
end

---@param fn function|nil
---@param name string
---@return any|nil
local function upvalue(fn, name)
    if type(fn) ~= "function" then return nil end
    for i = 1, 32 do
        local uname, value = debug.getupvalue(fn, i)
        if not uname then return nil end
        if uname == name then return value end
    end
end

---@return integer
function Slim.dropImageCache()
    local ImageWidget = package.loaded["ui/widget/imagewidget"]
    if not ImageWidget then return 0 end
    local cache = upvalue(ImageWidget._loadfile, "ImageCache")
    if type(cache) ~= "table" then return 0 end
    local n = 0
    local lru = cache.cache
    if lru and type(lru.pairs) == "function" then
        local items = {}
        for _key, item in lru:pairs() do
            items[#items + 1] = item
        end
        for _idx, item in ipairs(items) do
            if type(item) == "table" and item.bb then
                Slim.releaseBlit(item.bb)
                item.bb = nil
                n = n + 1
            end
        end
    end
    if type(cache.clear) == "function" then cache:clear() end
    return n
end

--- tile 有页图位图；版面信息、KOPT 上下文不要动，避免在子进程里拆文档。
---@param item any
---@return boolean
local function isTile(item)
    return type(item) == "table"
        and item.bb ~= nil
        and item.excerpt ~= nil
        and type(item.onFree) == "function"
end

---@return integer
function Slim.dropDocCacheTiles()
    local DocCache = package.loaded["document/doccache"]
    if not DocCache or type(DocCache.cache) ~= "table" or type(DocCache.cache.pairs) ~= "function" then
        return 0
    end
    local lru = DocCache.cache
    local tiles = {}
    for key, item in lru:pairs() do
        if isTile(item) then tiles[#tiles + 1] = { key = key, item = item } end
    end
    if type(lru.delete) ~= "function" then return 0 end
    local n = 0
    for _idx, tile in ipairs(tiles) do
        local bb = tile.item.bb
        local size = blitSize(bb)
        if size and bb and bb.data ~= nil then
            Slim.advisePrivate(bb.data, size)
        end
        -- delete 会走 TileCacheItem:onFree → bb:free()，这里不再 free，避免双释放。
        local ok, err = pcall(function() lru:delete(tile.key) end)
        if ok then
            n = n + 1
        else
            logger.warn("book.worker slim tile failed", err)
        end
    end
    return n
end

--- fork 之后、跑 worker 之前调用。失败只记日志，不阻断任务。
function Slim.afterFork()
    local bitmaps = Slim.dropPluginBitmaps()
    local images = Slim.dropImageCache()
    local tiles = Slim.dropDocCacheTiles()
    if bitmaps > 0 or images > 0 or tiles > 0 then
        logger.dbg("book.worker slim", "bitmaps=" .. bitmaps, "images=" .. images, "tiles=" .. tiles)
    end
end

return Slim
