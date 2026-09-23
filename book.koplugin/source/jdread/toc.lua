--[[--
京东读书目录缓存与章节 uid 定位。

@module koplugin.book.source.jdread.toc
--]]

local Toc = {}

local TTL = 6 * 60 * 60
local cache = {}
local CACHE_LIMIT = 32
local function putCache(key, value)
    cache[key] = value
    local count = 0
    for cached_key in pairs(cache) do count = count + 1; if count > CACHE_LIMIT then cache[cached_key] = nil; break end end
end

---@param string_id string
---@param stable_id string
---@return string
local function keyOf(string_id, stable_id)
    return string_id .. "\31" .. stable_id
end

---@param list BookChapter[]
---@return table
local function build(list, fetched_at)
    local by_uid = {}
    for _, chapter in ipairs(list) do
        if chapter.uid ~= nil then by_uid[tostring(chapter.uid)] = chapter.idx end
    end
    return { list = list, by_uid = by_uid, fetched_at = fetched_at }
end

---@param source_id string
---@param stable_id string
---@return table|nil
local function entry(source_id, stable_id)
    local key = keyOf(source_id, stable_id)
    local hit = cache[key]
    if hit and os.time() - hit.fetched_at < TTL then return hit end
    cache[key] = nil
    local payload, fetched_at = require("db.book").getToc(source_id, stable_id, TTL)
    if not payload then return nil end
    local ok, list = pcall(require("json").decode, payload)
    if not ok or type(list) ~= "table" then return nil end
    putCache(key, build(list, fetched_at or os.time()))
    return cache[key]
end

---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil
function Toc.read(source_id, stable_id)
    local hit = entry(source_id, stable_id)
    return hit and hit.list
end

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

---@param source_id string
---@param stable_id string
---@param uid string|number|nil
---@return integer|nil
function Toc.index(source_id, stable_id, uid)
    if uid == nil then return nil end
    local hit = entry(source_id, stable_id)
    return hit and hit.by_uid[tostring(uid)]
end

---@param source_id string
---@param stable_id string
---@param idx integer|nil
---@return string|nil
function Toc.uid(source_id, stable_id, idx)
    local hit = entry(source_id, stable_id)
    local chapter = hit and hit.list[tonumber(idx)]
    return chapter and chapter.uid
end

function Toc.clear()
    cache = {}
end

return Toc
