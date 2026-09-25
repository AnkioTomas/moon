--[[--
章节源目录缓存：books.toc（JSON 载荷）的读取、按 idx/uid 定位与进程内缓存。

目录只由本插件 ``Toc.put`` / ``Store.touch`` 写入，写入即失效重建，
翻页、按章补报统计这些高频路径不必反复查库 + decode 整份目录。
缓存键含 source_id，各章节源共用这一份。

@module koplugin.book.source.toc
--]]

local Toc = {}

--- 目录缓存 TTL（秒），与 Store.TOC_MAX_AGE 同源。
Toc.TTL = 6 * 60 * 60

---@class SourceTocEntry
---@field list BookChapter[]
---@field idx_by_uid table<string, integer>
---@field source_idx_by_idx table<integer, integer>
---@field fetched_at integer

---@type table<string, SourceTocEntry>
local cache = {}
local count = 0
local CACHE_LIMIT = 32

--- 写入缓存；超限时淘汰任意一条旧条目，绝不淘汰刚写入的这条。
---@param key string
---@param entry SourceTocEntry
---@return SourceTocEntry
local function putCache(key, entry)
    if cache[key] == nil then
        count = count + 1
    end
    cache[key] = entry
    if count > CACHE_LIMIT then
        for cached_key in pairs(cache) do
            if cached_key ~= key then
                cache[cached_key] = nil
                count = count - 1
                break
            end
        end
    end
    return entry
end

---@param key string
local function dropCache(key)
    if cache[key] ~= nil then
        cache[key] = nil
        count = count - 1
    end
end

---@param source_id string
---@param stable_id string
---@return string
local function keyOf(source_id, stable_id)
    return tostring(source_id) .. "\31" .. tostring(stable_id)
end

--- 建立 uid → idx、idx → 源原始序号反查表，省掉每次定位的线性扫。
---@param list BookChapter[]
---@param fetched_at integer
---@return SourceTocEntry
local function build(list, fetched_at)
    local idx_by_uid = {}
    local source_idx_by_idx = {}
    for _, chapter in ipairs(list) do
        if type(chapter) == "table" then
            local idx = tonumber(chapter.idx)
            if chapter.uid ~= nil then
                idx_by_uid[tostring(chapter.uid)] = idx
            end
            if idx and tonumber(chapter.source_idx) then
                source_idx_by_idx[idx] = tonumber(chapter.source_idx)
            end
        end
    end
    return { list = list, idx_by_uid = idx_by_uid, source_idx_by_idx = source_idx_by_idx,
        fetched_at = fetched_at }
end

--- 取解码后的目录条目；未命中/过期/非法 JSON 一律返回 nil。
---@param source_id string
---@param stable_id string
---@return SourceTocEntry|nil
local function entry(source_id, stable_id)
    local key = keyOf(source_id, stable_id)
    local hit = cache[key]
    if hit and os.time() - hit.fetched_at < Toc.TTL then
        return hit
    end
    dropCache(key)
    local payload, fetched_at = require("db.book").getToc(source_id, stable_id, Toc.TTL)
    if not payload then
        return nil
    end
    local ok, list = pcall(require("json").decode, payload)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return putCache(key, build(list, fetched_at or os.time()))
end

--- 读取并解码目录缓存；未命中/过期/非法 JSON 一律返回 nil。
---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id)
    local hit = entry(source_id, stable_id)
    return hit and hit.list
end

--- 落库并接管内存缓存（目录刚拉到手，无需再 decode 一遍）。
---@param source_id string
---@param stable_id string
---@param list BookChapter[]
---@return boolean
function Toc.put(source_id, stable_id, list)
    local ok, payload = pcall(require("json").encode, list)
    if not ok or type(payload) ~= "string" then return false end
    if not require("db.book").setToc(source_id, stable_id, payload) then return false end
    putCache(keyOf(source_id, stable_id), build(list, os.time()))
    return true
end

--- 按 chapter.uid 反查 chapter.idx。
---@param source_id string
---@param stable_id string
---@param uid string|number|nil
---@return integer|nil
function Toc.index(source_id, stable_id, uid)
    if uid == nil then return nil end
    local hit = entry(source_id, stable_id)
    return hit and hit.idx_by_uid[tostring(uid)]
end

--- 按 1-based 章节序号取 chapter.uid。
---@param source_id string
---@param stable_id string
---@param idx integer|nil
---@return string|nil
function Toc.uid(source_id, stable_id, idx)
    local hit = entry(source_id, stable_id)
    local chapter = hit and hit.list[tonumber(idx)]
    return chapter and chapter.uid
end

--- 按本地章节序号取源原始章节序号。
---@param source_id string
---@param stable_id string
---@param idx number|nil
---@return integer|nil
function Toc.sourceIndex(source_id, stable_id, idx)
    local hit = entry(source_id, stable_id)
    return hit and hit.source_idx_by_idx[tonumber(idx)]
end

--- 章序号 + 章内比例 → 全书 fraction；目录未缓存时返回 nil。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param chapter_fraction number|nil
---@return number|nil
function Toc.wholeFraction(source_id, stable_id, chapter_idx, chapter_fraction)
    local list = Toc.read(source_id, stable_id)
    if not list or #list == 0 then return nil end
    return require("book.progress").clampFraction(
        (chapter_idx - 1 + (chapter_fraction or 0)) / #list
    )
end

--- 丢掉一本的进程内目录缓存；落库的 books.toc 不受影响。
---@param source_id string
---@param stable_id string
function Toc.invalidate(source_id, stable_id)
    dropCache(keyOf(source_id, stable_id))
end

--- 清空进程内目录缓存；落库的 books.toc 不受影响。
function Toc.clear()
    cache = {}
    count = 0
end

return Toc
